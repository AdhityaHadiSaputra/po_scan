import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:metrox_po/models/db_helper.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
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
  List<Map<String, dynamic>> scannedResults = [];
  bool isLoading = true;
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? controller;
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    fetchPODetails(); // Fetch PO details when the page loads
    fetchScannedResults(); // Fetch scanned results when the page loads
  }

  void playBeep() async {
    await _audioPlayer.play(AssetSource('beep.mp3'));
  }

  Future<void> fetchPODetails() async {
    final List<Map<String, dynamic>> details =
        await dbHelper.getPODetails(widget.poNumber);
    setState(() {
      poDetails = details;
      isLoading = false;
    });
  }

  Future<void> fetchScannedResults() async {
    try {
      final List<Map<String, dynamic>> results =
          await dbHelper.getScannedPODetails(widget.poNumber);
      setState(() {
        scannedResults = results;
      });
    } catch (e) {
      print('Error fetching scanned results: $e');
    }
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
      print('Found item: ${item['item_name']}'); // Debugging
      _showQtyInputDialog(item, scannedCode);
      return;
    }
  }

  // If no match found, check if the barcode already exists in scannedResults
  if (!scannedResults.any((result) => result['barcode'] == scannedCode)) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No matching item found for scanned barcode')),
    );
  }
}



  void _showQtyInputDialog(Map<String, dynamic> item, String scannedCode) {
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
                  int qtyPO =
                      int.tryParse(updatedItem['qty_po']?.toString() ?? '0') ??
                          0;
                  int existingQty =
                      int.tryParse(updatedItem['qty_scanned']?.toString() ??
                          '0') ??
                          0;

                  int newQtyScanned = existingQty + inputQty;
                  int qtyDifferent =
                      (newQtyScanned > qtyPO) ? newQtyScanned - qtyPO : 0;

                  updatedItem['qty_scanned'] =
                      newQtyScanned > qtyPO ? qtyPO : newQtyScanned;
                  updatedItem['qty_different'] = qtyDifferent;

                  await dbHelper.updatePOItem(
                    widget.poNumber,
                    updatedItem['barcode'],
                    updatedItem['qty_scanned'],
                    qtyDifferent,
                  );

                  fetchPODetails();
                  fetchScannedResults(); // Fetch latest scanned results from the database
                }

                Navigator.of(context).pop(); // Close input dialog
              },
              child: Text('Confirm'),
            ),
          ],
        );
      },
    );
  }

  void _editItem(Map<String, dynamic> item) {
    TextEditingController _qtyScannedController =
        TextEditingController(text: item['qty_scanned'].toString());

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
                Navigator.of(context).pop(); // Close dialog if Cancel is pressed
              },
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                int qtyPO = int.tryParse(item['qty_po'].toString()) ?? 0;
                int newQtyScanned =
                    int.tryParse(_qtyScannedController.text) ?? 0;
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
                fetchScannedResults(); // Refresh scanned results

                Navigator.of(context).pop();
              },
              child: Text('Save'),
            ),
          ],
        );
      },
    );
  }
    void _deleteScannedResult(String barcode) async {
    await dbHelper.deletePOResult(widget.poNumber);
    fetchScannedResults(); // Refresh the scanned results after deletion
  }

  void submitScannedResults() async {
  final url = 'http://108.136.252.63:8080/pogr/trans.php';
  final userId = 'ahmad.syahru';
  
  List<Map<String, dynamic>> dataScan = scannedResults.map((item) {
    return {
      "pono": item['pono'],
      "itemsku": item['item_sku'],
      "skuname": item['item_name'],
      "barcode": item['vendorbarcode'] ?? '',
      "vendorbarcode": item['barcode'],
      "qty": item['qty_scanned'].toString(),
      "scandate": item['scandate'], // Ensure this is in correct format
      "machinecd": item['device_name'] // Replace with your actual machine ID
    };
  }).toList();

  // Assuming qty_over data is similar to scanned results, adjust if necessary


  final body = json.encode({
    "USERID": userId,
    "DATASCAN": dataScan,
   
  });

  try {
    final response = await http.post(
      Uri.parse(url),
      headers: {"Content-Type": "application/json"},
      body: body,
    );

    if (response.statusCode == 200) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Data submitted successfully')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to submit data: ${response.body}')),
      );
    }
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Error: $e')),
    );
  }
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
                          columns: const [
                            DataColumn(label: Text('Item SKU')),
                            DataColumn(label: Text('Item Name')),
                            DataColumn(label: Text('Barcode')),
                            DataColumn(label: Text('Quantity PO')),
                            DataColumn(label: Text('Quantity Scanned')),
                            DataColumn(label: Text('Quantity Over')),
                            DataColumn(label: Text('Scan Date')),
                            DataColumn(label: Text('Device Name')),
                            DataColumn(label: Text('Actions')),
                          ],
                          rows: poDetails.map((detail) {
                            return DataRow(cells: [
                              DataCell(Text(detail['item_sku'] ?? '')),
                              DataCell(Text(detail['item_name'] ?? '')),
                              DataCell(Text(detail['barcode'] ?? '')),
                              DataCell(Text(detail['qty_po'].toString())),
                              DataCell(Text((detail['qty_scanned'] ?? 0)
                                  .toString())),
                              DataCell(Text((detail['qty_different'] ?? 0)
                                  .toString())),
                              DataCell(Text(detail['scandate'] != null
                                  ? DateFormat('yyyy-MM-dd HH:mm:ss')
                                      .format(DateTime.parse(detail['scandate']))
                                  : '')),
                              DataCell(Text(detail['device_name'] ?? '')),
                              DataCell(
                                Row(
                                  children: [
                                    TextButton(
                                      onPressed: () {
                                        _startScanningForItem(
                                            detail['barcode'] ?? '');
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
                      SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('PONO')),
                            DataColumn(label: Text('Item SKU')),
                            DataColumn(label: Text('Item SKU Name')),
                            DataColumn(label: Text('Barcode')),
                            DataColumn(label: Text('VendorBarcode')),
                            DataColumn(label: Text('QTY')),
                            DataColumn(label: Text('AudUser')),
                            DataColumn(label: Text('AudDate')),
                            DataColumn(label: Text('MachineCd')),
                            DataColumn(label: Text('Actions')),

                           
                          ],
                          rows: scannedResults.map((detail) {
                            return DataRow(cells: [
                              DataCell(Text(detail['pono'] ?? '')),
                              DataCell(Text(detail['item_sku'] ?? '')),
                              DataCell(Text(detail['item_name'] ?? '')),
                              DataCell(Text(detail['vendorbarcode'] ?? '')),
                              DataCell(Text(detail['barcode'] ?? '')),
                              
                              DataCell(Text((detail['qty_scanned'] ?? 0)
                                  .toString())),
                              DataCell(Text(detail['user'] ?? '')),
                              DataCell(Text(detail['scandate'] != null
                                  ? DateFormat('yyyy-MM-dd HH:mm:ss')
                                      .format(DateTime.parse(detail['scandate']))
                                  : '')),
                              DataCell(Text(detail['device_name'] ?? '')),
                              DataCell(
                                Row(
                                  children: [
                                    TextButton(
                                      onPressed: () {
                                        _deleteScannedResult(
                                            detail['barcode'] ?? '');
                                      },
                                      child: Icon(Icons.delete),
                                    ),
                            ])
                              )
                            ]);
                          }).toList(),
                        ),
                        
                      ),
                      SizedBox(height: 20), // Add some spacing
                    Center(
                      child: ElevatedButton(
                        onPressed: submitScannedResults,
                        child: Text('Submit Results'),
                      ),
                    ),
                    ],
                  ),
                ),
                  ])));
              
    
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
