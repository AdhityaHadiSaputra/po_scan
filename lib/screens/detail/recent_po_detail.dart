import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:metrox_po/models/db_helper.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';

class PODetailPage extends StatefulWidget {
  final String poNumber;

  PODetailPage({required this.poNumber});

  @override
  _PODetailPageState createState() => _PODetailPageState();
}

class _PODetailPageState extends State<PODetailPage> {
  final DatabaseHelper dbHelper = DatabaseHelper();
  List<Map<String, dynamic>> poDetails = [];
  bool isLoading = true;
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? controller;
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    fetchPODetails(); // Fetch PO details when the page loads
  }

  void playBeep() async {
    await _audioPlayer.play(AssetSource('beep.mp3'));
  }

  Future<void> fetchPODetails() async {
    final List<Map<String, dynamic>> details = await dbHelper.getPODetails(widget.poNumber);
    setState(() {
      poDetails = details;
      isLoading = false;
    });
  }

  void _startScanningForItem(String barcode) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => QRScannerPage(
          onQRScanned: (String scannedBarcode) {
            print('Scanned Barcode: $scannedBarcode'); // For debugging
            checkAndSumQty(scannedBarcode);
          },
          playBeep: playBeep, // Pass the playBeep function
        ),
      ),
    );
  }

  void checkAndSumQty(String scannedCode) {
    for (var item in poDetails) {
      if (item['barcode'] == scannedCode) {
        _showQtyInputDialog(item);
        return;
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No matching item found for scanned barcode')),
    );
  }

  void _showQtyInputDialog(Map<String, dynamic> item) {
    Navigator.of(context).pop();
    TextEditingController _qtyController = TextEditingController(text: '');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Input Quantity for ${item['item_name']}'),
          content: TextField(
            controller: _qtyController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Quantity',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog if Cancel is pressed
              },
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                int inputQty = int.tryParse(_qtyController.text) ?? 0;

                if (inputQty > 0) {
                  var updatedItem = Map<String, dynamic>.from(item);

                  int qtyPO = int.tryParse(updatedItem['qty_po']?.toString() ?? '0') ?? 0;
                  int existingQty = int.tryParse(updatedItem['qty_scanned']?.toString() ?? '0') ?? 0;

                  int newQtyScanned = existingQty + inputQty;
                  int qtyDifferent = (newQtyScanned > qtyPO) ? newQtyScanned - qtyPO : 0;

                  updatedItem['qty_scanned'] = newQtyScanned > qtyPO ? qtyPO : newQtyScanned;
                  updatedItem['qty_different'] = qtyDifferent;

                  await dbHelper.updatePOItem(
                    widget.poNumber,
                    updatedItem['barcode'],
                    updatedItem['qty_scanned'],
                    qtyDifferent,
                  );

                  fetchPODetails();
                }

                Navigator.of(context)
                  ..pop() // Close input dialog
                  ..pop(); // Close QRScannerPage
              },
              child: Text('Confirm'),
            ),
          ],
        );
      },
    );
  }

  void _editItem(Map<String, dynamic> item) {
    TextEditingController _qtyScannedController = TextEditingController(text: item['qty_scanned'].toString());

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Edit Item ${item['item_name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _qtyScannedController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'Quantity Scanned'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Tutup dialog jika Cancel ditekan
              },
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                int qtyPO = int.tryParse(item['qty_po'].toString()) ?? 0;
                int newQtyScanned = int.tryParse(_qtyScannedController.text) ?? 0;
                int qtyOver = 0;

                if (newQtyScanned > qtyPO) {
                  qtyOver = newQtyScanned - qtyPO;
                  newQtyScanned = qtyPO;
                }

                await dbHelper.updatePOItem(
                  widget.poNumber,
                  item['barcode'],
                  newQtyScanned,
                  qtyOver,
                );

                fetchPODetails();

                Navigator.of(context).pop();
              },
              child: Text('Save'),
            ),
          ],
        );
      },
    );
  }

  // void _postPO() async {
  //   // Mark PO as "Posted" in the database
  //   await dbHelper.postPO(widget.poNumber);

  //   ScaffoldMessenger.of(context).showSnackBar(
  //     SnackBar(content: Text('PO ${widget.poNumber} has been posted.')),
  //   );

  //   Navigator.of(context).pop(); // Go back to previous screen
  // }

  void _navigateToReviewPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReviewPage(poNumber: widget.poNumber, poDetails: poDetails),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.poNumber}'),
      ),
      body: isLoading
          ? Center(child: CircularProgressIndicator())
          : poDetails.isEmpty
              ? Center(child: Text('No details found for this PO'))
              : SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns:const [
                            DataColumn(label: Text('Item SKU')),
                            DataColumn(label: Text('Item Name')),
                            DataColumn(label: Text('Barcode')),
                            DataColumn(label: Text('Quantity PO')),
                            DataColumn(label: Text('Quantity Scanned')),
                            DataColumn(label: Text('Quantity Over')),
                            DataColumn(label: Text('Device Name')),
                            DataColumn(label: Text('Actions')),
                          ],
                          rows: poDetails.map((detail) {
                            return DataRow(cells: [
                              DataCell(Text(detail['item_sku'] ?? '')),
                              DataCell(Text(detail['item_name'] ?? '')),
                              DataCell(Text(detail['barcode'] ?? '')),
                              DataCell(Text(detail['qty_po'].toString())),
                              DataCell(Text((detail['qty_scanned'] ?? 0).toString())),
                              DataCell(Text((detail['qty_different'] ?? 0).toString())),
                              DataCell(Text(detail['device_name'] ?? '')),
                              DataCell(
                                Row(
                                  children: [
                                    TextButton(
                                      onPressed: () {
                                        _startScanningForItem(detail['barcode'] ?? '');
                                      },
                                      child: Icon(Icons.qr_code_scanner_rounded),
                                    ),
                                    SizedBox(width: 8),
                                    TextButton(
                                      onPressed: () {
                                        _editItem(detail);
                                      },
                                      child: Icon(Icons.edit),
                                    ),
                                  ],
                                ),
                              ),
                            ]);
                          }).toList(),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            ElevatedButton(
                              onPressed: _navigateToReviewPage,
                              child: Text('Review'),
                            ),
                            // ElevatedButton(
                            //   onPressed: _postPO,
                            //   child: Text('Posted'),
                            //   style: ElevatedButton.styleFrom(primary: Colors.green),
                            // ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class ReviewPage extends StatelessWidget {
  final String poNumber;
  final List<Map<String, dynamic>> poDetails;

  ReviewPage({required this.poNumber, required this.poDetails});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Review PO: $poNumber'),
      ),
      body: poDetails.isEmpty
          ? Center(child: Text('No items to review for this PO'))
          : SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Item SKU')),
                    DataColumn(label: Text('Item Name')),
                    DataColumn(label: Text('Barcode')),
                    DataColumn(label: Text('Quantity PO')),
                    DataColumn(label: Text('Quantity Scanned')),
                    DataColumn(label: Text('Quantity Over')),
                    DataColumn(label: Text('Device Name')),
                  ],
                  rows: poDetails.map((detail) {
                    return DataRow(cells: [
                      DataCell(Text(detail['item_sku'] ?? '')),
                      DataCell(Text(detail['item_name'] ?? '')),
                      DataCell(Text(detail['barcode'] ?? '')),
                      DataCell(Text(detail['qty_po'].toString())),
                      DataCell(Text((detail['qty_scanned'] ?? 0).toString())),
                      DataCell(Text((detail['qty_different'] ?? 0).toString())),
                      DataCell(Text(detail['device_name'] ?? '')),
                    ]);
                  }).toList(),
                ),
              ),
            ),
    );
  }
}

class QRScannerPage extends StatelessWidget {
  final Function(String) onQRScanned;
  final VoidCallback playBeep;

  QRScannerPage({required this.onQRScanned, required this.playBeep});

  @override
  Widget build(BuildContext context) {
    final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');

    return Scaffold(
      appBar: AppBar(title: Text('Scan QR Code')),
      body: QRView(
        key: qrKey,
        onQRViewCreated: (QRViewController controller) {
          controller.scannedDataStream.listen((scanData) {
            print('Scanned Data: ${scanData.code}'); // Debugging scan data
            if (scanData.code != null) {
              playBeep(); // Play beep sound when a QR code is scanned
              onQRScanned(scanData.code!); // Ensure code is not null
            }
          });
        },
        overlay: QrScannerOverlayShape(
          borderColor: Colors.red,
          borderRadius: 10,
          borderLength: 30,
          borderWidth: 10,
          cutOutSize: 300,
        ),
      ),
    );
  }
}
