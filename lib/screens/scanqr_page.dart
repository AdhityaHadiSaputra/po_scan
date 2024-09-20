import 'package:audioplayers/audioplayers.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:metrox_po/drawer.dart';
import 'package:metrox_po/models/db_helper.dart';
import 'package:metrox_po/screens/detail/master_item.dart';
import 'package:metrox_po/utils/list_extensions.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api_service.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

final formatQTYRegex = RegExp(r'([.]*0+)(?!.*\d)');

class ScanQRPage extends StatefulWidget {
  final Map<String, dynamic>? initialPOData;

  const ScanQRPage({super.key, this.initialPOData});

  @override
  State<ScanQRPage> createState() => _ScanQRPageState();
}

class _ScanQRPageState extends State<ScanQRPage> {
  final Apiuser apiuser = Apiuser();
  final DatabaseHelper dbHelper = DatabaseHelper();
  List<Map<String, dynamic>> detailPOData = [];
  List<Map<String, dynamic>> notInPOItems = []; // Items fetched from master item that are not in PO

  bool isLoading = false;
  final TextEditingController _poNumberController = TextEditingController();
  QRViewController? controller;
  String scannedBarcode = "";
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    if (widget.initialPOData != null) {
      detailPOData = [widget.initialPOData!];
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    _audioPlayer.dispose(); // Dispose the audio player when not in use
    super.dispose();
  }

  void playBeep() async {
    await _audioPlayer.play(AssetSource('beep.mp3'));
  }

  Future<void> fetchPOData(String pono) async {
    setState(() => isLoading = true);

    try {
      final response = await apiuser.fetchPO(pono);

      if (response.containsKey('code') && response['code'] == '1') {
        final msg = response['msg'];
        final headerPO = msg['HeaderPO'];
        final localPOs = await dbHelper.getPODetails(headerPO[0]['PONO']);
        final detailPOList = List<Map<String, dynamic>>.from(msg['DetailPO']);

        setState(() {
          detailPOData = detailPOList.map((item) {
            final product = localPOs.firstWhereOrNull((product) => product["barcode"] == item["BARCODE"]);
            if (product != null) {
              item["QTYD"] = product["qty_different"];
              item["QTYS"] = product["qty_scanned"];
            }
            return item;
          }).toList();
        });
      } else {
        _showErrorSnackBar('Request failed: ${response['code']}');
      }
    } catch (error) {
      _showErrorSnackBar('Error fetching PO: $error');
    } finally {
      setState(() => isLoading = false);
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  
  Future<void> submitDataToDatabase() async {
  String poNumber = _poNumberController.text.trim();

  if (poNumber.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Please search for a PO before submitting data')),
    );
    return;
  }

  final deviceInfoPlugin = DeviceInfoPlugin();
  String deviceName = '';

  if (GetPlatform.isAndroid) {
    final androidInfo = await deviceInfoPlugin.androidInfo;
    deviceName = '${androidInfo.brand} ${androidInfo.model}';
  } else if (GetPlatform.isIOS) {
    final iosInfo = await deviceInfoPlugin.iosInfo;
    deviceName = '${iosInfo.name} ${iosInfo.systemVersion}';
  } else {
    deviceName = 'Unknown Device';
  }

  // Insert PO data
  for (var item in detailPOData) {
    final poData = {
      'pono': poNumber,
      'item_sku': item['ITEMSKU'],
      'item_name': item['ITEMSKUNAME'],
      'barcode': item['BARCODE'],
      'qty_po': item['QTYPO'],
      'qty_scanned': item['QTYS'] ?? 0,
      'qty_different': item['QTYD'] ?? 0,
      'device_name': deviceName,
    };

    await dbHelper.insertOrUpdatePO(poData);
  }

  // Insert not in PO items
  await dbHelper.insertNotInPOItems(notInPOItems.map((item) {
    return {
      'pono': poNumber,
      'item_sku': item['ITEMSKU'],
      'item_name': item['ITEMSKUNAME'],
      'barcode': item['BARCODE'],
      'qty_scanned': item['QTYS'] ?? 0,
      'qty_different': item['QTYD'] ?? 0,
      'device_name': deviceName,
    };
  }).toList());

  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('PO data and non-PO items saved to local database')),
  );
}
  void _onQRViewCreated(QRViewController qrController) {
    setState(() {
      controller = qrController;
    });

    controller!.scannedDataStream.listen((scanData) {
      setState(() {
        scannedBarcode = scanData.code ?? "";
      });

      if (scannedBarcode.isNotEmpty) {
        playBeep();
        checkAndSumQty(scannedBarcode);
        controller?.pauseCamera();
        Future.delayed(const Duration(seconds: 2), () {
          controller?.resumeCamera();
        });
      }
    });
  }

  Future<void> checkAndSumQty(String scannedCode) async {
  final item = detailPOData.firstWhereOrNull(
    (item) => item['BARCODE'] == scannedCode || item['ITEMSKU'] == scannedCode || item['VENDORBARCODE'] == scannedCode,
  );

  if (item != null) {
    // If item exists in PO list, update its quantity
    int poQty = int.tryParse((item['QTYPO'] as String).replaceAll(formatQTYRegex, '')) ?? 0;
    int scannedQty = int.tryParse(item['QTYS']?.toString() ?? '0') ?? 0;
    int newScannedQty = scannedQty + 1;

    item['QTYS'] = newScannedQty > poQty ? poQty : newScannedQty;
    item['QTYD'] = newScannedQty > poQty ? newScannedQty - poQty : 0;

    updatePO(item);
  } else {
    // Item not found in PO, make API call to check in the master item table
    final masterItem = await fetchMasterItem(scannedCode);

    if (masterItem != null) {
      // Check if item is already in the non-PO list
      final existingItem = notInPOItems.firstWhereOrNull((e) => e['BARCODE'] == scannedCode);
      
      if (existingItem != null) {
        // Update quantity for the item in notInPOItems
        int scannedQty = int.tryParse(existingItem['QTYS']?.toString() ?? '0') ?? 0;
        int newScannedQty = scannedQty + 1;
        existingItem['QTYS'] = newScannedQty;
        existingItem['QTYD'] = newScannedQty;
      } else {
        // Add item to the notInPOItems list
        masterItem['QTYS'] = 1; // Start with scanned quantity of 1
        masterItem['QTYD'] = 1; // Quantity difference is the same as scanned in this case
        notInPOItems.add(masterItem);
      }

      setState(() {});
    } else {
      _showErrorSnackBar('No matching item found in master item table');
    }
  }
}
Future<Map<String, dynamic>?> fetchMasterItem(String scannedCode) async {
    const url = 'http://108.136.252.63:8080/pogr/getmaster.php';
    const brand = 'YEC';

    try {
      var request = http.MultipartRequest('POST', Uri.parse(url));
      request.fields['ACTION'] = 'GETITEM';
      request.fields['BRAND'] = brand;
      request.fields['BARCODE'] = scannedCode;

      // Log the request details
      print("Request fields: ${request.fields}");

      var response = await request.send();

      // Check the status code
      print("Response status: ${response.statusCode}");

      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        
        // Print the full response data
        print("Response body: $responseData");

        var jsonResponse = json.decode(responseData);

        // Log the JSON response
        print("Parsed JSON: $jsonResponse");

        if (jsonResponse['code'] == '1' && jsonResponse['msg'] is List) {
          List<dynamic> itemList = jsonResponse['msg'];

          // Log the item list
          print("Item list: $itemList");

          if (itemList.isNotEmpty) {
            return itemList.first as Map<String, dynamic>;
          } else {
            return null;
          }
        } else {
          _showErrorSnackBar('Invalid response format');
          return null;
        }
      } else {
        _showErrorSnackBar('Failed to fetch item from master table');
        return null;
      }
    } catch (error) {
      _showErrorSnackBar('Error fetching master item: $error');
      return null;
    }
  }


  void _showQtyInputDialog(Map<String, dynamic> item) {
    Navigator.of(context).pop();
    TextEditingController qtyController = TextEditingController(text: '');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Input Quantity for ${item['ITEMSKUNAME']}'),
          content: TextField(
            controller: qtyController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Quantity',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                int inputQty = int.tryParse(qtyController.text) ?? 0;

                if (inputQty > 0) {
                  int poQty = int.tryParse((item['QTYPO'] as String).replaceAll(formatQTYRegex, '')) ?? 0;
                  int scannedQty = int.tryParse(item['QTYS']?.toString() ?? '0') ?? 0;
                  int newScannedQty = scannedQty + inputQty;

                  bool isLargerThanQTYPO = newScannedQty > poQty;

                  item['QTYS'] = isLargerThanQTYPO ? poQty : newScannedQty;
                  item['QTYD'] = isLargerThanQTYPO ? (poQty - newScannedQty).abs() : 0;

                  updatePO(item);
                }

                Navigator.of(context).pop();
              },
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    );
  }

  Future<void> updatePO(Map<String, dynamic> item) async {
    detailPOData = detailPOData.replaceOrAdd(
      item, 
      (po) => po['BARCODE'] == item["BARCODE"]
    );
    setState(() {});
    savePOToRecent(_poNumberController.text);
    submitDataToDatabase();
  }

  Future<void> savePOToRecent(String updatedPONO) async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? recentNoPOs = prefs.getStringList('recent_pos') ?? [];

    recentNoPOs = recentNoPOs.replaceOrAdd(
      updatedPONO,
      (pono) => pono == updatedPONO
    );
    await prefs.setStringList('recent_pos', recentNoPOs);
  }

  @override
Widget build(BuildContext context) {
  return Scaffold(
    resizeToAvoidBottomInset: false,
    appBar: AppBar(
      title: const Text('PO Details'),
    ),
    drawer: const MyDrawer(),
    body: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _poNumberController,
                  decoration: const InputDecoration(
                    labelText: 'Enter PO Number',
                    border: OutlineInputBorder(),
                  ),
                  inputFormatters: [UpperCaseTextFormatter()],
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: () {
                  String poNumber = _poNumberController.text.trim();
                  if (poNumber.isNotEmpty) {
                    fetchPOData(poNumber);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Please enter a valid PO number'),
                      ),
                    );
                  }
                },
                child: const Icon(Icons.search),
              ),
            ],
          ),
          const SizedBox(height: 20),
          isLoading
              ? const Center(child: CircularProgressIndicator())
              : Expanded(
                  child: Column(
                    children: [
                      if (detailPOData.isEmpty)
                        const Center(child: Text('Search for a PO to see details'))
                      else
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(
                              child: SingleChildScrollView(
                                  scrollDirection: Axis.vertical,
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                  child: DataTable(
                                    columns: const [
                                      DataColumn(label: Text('Item SKU')),
                                      DataColumn(label: Text('Item Name')),
                                      DataColumn(label: Text('Barcode')),
                                      DataColumn(label: Text('Qty PO')),
                                      DataColumn(label: Text('Qty Scanned')),
                                      DataColumn(label: Text('Qty Over')),
                                      DataColumn(label: Text('Device Name')),
                                    ],
                                    rows: detailPOData.map(
                                      (e) => DataRow(
                                        cells: [
                                          DataCell(Text(e['ITEMSKU']?.toString() ?? '')),
                                          DataCell(Text(e['ITEMSKUNAME']?.toString() ?? '')),
                                          DataCell(Text(e['BARCODE']?.toString() ?? '')),
                                          DataCell(Text(e['QTYPO']?.toString() ?? '')),
                                          DataCell(Text(e['QTYS']?.toString() ?? '0')),
                                          DataCell(Text((e['QTYD'] ?? 0).toString())),
                                          DataCell(Text(e['device_name']?.toString() ?? 'Unknown Device')),
                                        ],
                                      ),
                                    ).toList(),
                                  ),
                                ),
                              ),
                              ),
                              const SizedBox(height: 20),
                              if (notInPOItems.isNotEmpty)
                                Expanded(
                                  child: SingleChildScrollView(
                                  scrollDirection: Axis.vertical,
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Column(
                                      children: [
                                        const Text('Items Not In PO'),
                                        DataTable(
                                          columns: const [
                                            DataColumn(label: Text('Item SKU')),
                                            DataColumn(label: Text('Item Name')),
                                            DataColumn(label: Text('Barcode')),
                                            DataColumn(label: Text('Qty Scanned')),
                                            DataColumn(label: Text('Qty Over')),
                                            DataColumn(label: Text('Device Name')),
                                          ],
                                          rows: notInPOItems.map(
                                            (e) => DataRow(
                                              cells: [
                                                DataCell(Text(e['ITEMSKU']?.toString() ?? '')),
                                                DataCell(Text(e['ITEMSKUNAME']?.toString() ?? '')),
                                                DataCell(Text(e['BARCODE']?.toString() ?? '')),
                                                DataCell(Text(e['QTYS']?.toString() ?? '0')),
                                                DataCell(Text((e['QTYD'] ?? 0).toString())),
                                                DataCell(Text(e['device_name']?.toString() ?? 'Unknown Device')),
                                              ],
                                            ),
                                          ).toList(),
                                        ),
                                      ],
                                    ),
                                  ),
                                  ),
                                ),
                              const SizedBox(height: 20),
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => QRViewExample(
                                        onQRViewCreated: _onQRViewCreated,
                                        onScanComplete: () {},
                                      ),
                                    ),
                                  ).then((_) {
                                    // Refresh data if needed
                                  });
                                },
                                child: const Text('Scan QR Code'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
        ],
      ),
    ),
  );
}
}

class QRViewExample extends StatelessWidget {
  final void Function(QRViewController) onQRViewCreated;
  final VoidCallback onScanComplete;

  const QRViewExample({
    super.key,
    required this.onQRViewCreated,
    required this.onScanComplete,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: QRView(
        key: GlobalKey(debugLabel: 'QR'),
        onQRViewCreated: onQRViewCreated,
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

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}