import 'package:audioplayers/audioplayers.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:metrox_po/drawer.dart';
import 'package:metrox_po/models/db_helper.dart';
import 'package:metrox_po/screens/detail/master_item.dart';
import 'package:metrox_po/utils/list_extensions.dart';
import 'package:metrox_po/utils/storage.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api_service.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'package:intl/intl.dart';

final formatQTYRegex = RegExp(r'([.]*0+)(?!.*\d)');

class ScanQRPage extends StatefulWidget {
  final Map<String, dynamic>? initialPOData;

  const ScanQRPage({super.key, this.initialPOData});

  @override
  State<ScanQRPage> createState() => _ScanQRPageState();
}

class _ScanQRPageState extends State<ScanQRPage> {
  final Apiuser apiuser = Apiuser();
  final StorageService storageService = StorageService.instance;
  final ApiService apiservice = ApiService();
  final DatabaseHelper dbHelper = DatabaseHelper();
  List<Map<String, dynamic>> detailPOData = [];
  List<Map<String, dynamic>> notInPOItems =
      []; // Items fetched from master item that are not in PO
  List<Map<String, dynamic>> scannedResults =
      []; // New list to hold scanned results
  bool isLoading = false;
  final TextEditingController _poNumberController = TextEditingController();
  QRViewController? controller;
  String scannedBarcode = "";
  late String userId = '';

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
      final userData = storageService.get(StorageKeys.USER);
      final response = await apiservice.loginUser(
        userData['USERID'],
        userData['USERPASSWORD'],
      );
      print(response);

      // Check if the response is not null and contains a 'code' field
      if (response.containsKey('code')) {
        final resultCode = response['code'];

        setState(() {
          // Check the 'code' to determine if the request was successful
          if (resultCode == "1") {
            // Extract USERID from the response and set it in the state
            final List<dynamic> msgList = response['msg'];
            if (msgList.isNotEmpty && msgList[0] is Map<String, dynamic>) {
              final Map<String, dynamic> msgMap =
                  msgList[0] as Map<String, dynamic>;
              userId = msgMap[
                  'USERID']; // Assuming USERID is in the first map of the list
            }
          } else {
            // Handle the case where the request was not successful
            print('Request failed with code $resultCode');
            print(response["msg"]);
          }
        });
      } else {
        // Handle the case where the response structure is unexpected
        print('Unexpected response structure');
      }
    } catch (error) {
      // Handle error, e.g., display an error message to the user
      print('Error: $error');
    }
    try {
      final response = await apiuser.fetchPO(pono);

      if (response.containsKey('code') && response['code'] == '1') {
        final msg = response['msg'];
        final headerPO = msg['HeaderPO'];
        final localPOs = await dbHelper.getPODetails(headerPO[0]['PONO']);
        final detailPOList = List<Map<String, dynamic>>.from(msg['DetailPO']);

        setState(() {
          detailPOData = detailPOList.map((item) {
            final product = localPOs.firstWhereOrNull(
                (product) => product["barcode"] == item["BARCODE"]);
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> submitDataToDatabase() async {
    String poNumber = _poNumberController.text.trim();

    if (poNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please search for a PO before submitting data')),
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

    String scandate = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

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
        'scandate': scandate,
      };

      await dbHelper.insertOrUpdatePO(poData);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PO data saved')),
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
      (item) =>
          item['BARCODE'] == scannedCode ||
          item['ITEMSKU'] == scannedCode ||
          item['VENDORBARCODE'] == scannedCode,
    );
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

    if (item != null) {
      int poQty = int.tryParse(
              (item['QTYPO'] as String).replaceAll(formatQTYRegex, '')) ??
          0;
      int scannedQty = int.tryParse(item['QTYS']?.toString() ?? '0') ?? 0;

      if (scannedQty < poQty) {
        int newScannedQty = scannedQty + 1;

        item['QTYS'] = newScannedQty > poQty ? poQty : newScannedQty;
        item['QTYD'] = newScannedQty > poQty ? newScannedQty - poQty : 0;

        item['scandate'] =
            DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

        // Add to scanned results
        scannedResults.add({
          'pono': _poNumberController.text.trim(),
          'item_sku': item['ITEMSKU'],
          'item_name': item['ITEMSKUNAME'],
          'barcode': scannedCode,
          'qty_scanned': 1,
          'user': userId,
          'device_name': deviceName,
          'scandate': item['scandate'],
        });

        updatePO(item);
        await submitScannedResults();
        setState(() {}); // Update UI
      } else {
        _showErrorSnackBar(
            'Scanned quantity for this item already meets or exceeds PO quantity.');
      }
    } else {
      // Handle master item fetching as before...
      final masterItem = await fetchMasterItem(scannedCode);
      if (masterItem != null) {
        handleMasterItemScanned(masterItem, scannedCode);
      } else {
        _showErrorSnackBar('No matching item found in master item table');
      }
    }
  }

  void handleMasterItemScanned(
      Map<String, dynamic> masterItem, String scannedCode) {
    final existingItem =
        notInPOItems.firstWhereOrNull((e) => e['BARCODE'] == scannedCode);

    if (existingItem != null) {
      int scannedQty =
          int.tryParse(existingItem['QTYS']?.toString() ?? '0') ?? 0;
      existingItem['QTYS'] = scannedQty + 1; // Increment for not in PO items
      existingItem['scandate'] =
          DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    } else {
      masterItem['QTYS'] = 1; // New item
      masterItem['scandate'] =
          DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
      notInPOItems.add(masterItem);
    }

    setState(() {}); // Update UI
  }

  Future<void> submitScannedResults() async {
    for (var result in scannedResults) {
      final scannedData = {
        'pono': result['pono'],
        'item_sku': result['item_sku'],
        'item_name': result['item_name'],
        'barcode': result['barcode'],
        'qty_scanned': result['qty_scanned'],
        'user': result['user'],
        'device_name': result['device_name'],
        'scandate': result['scandate'],
      };

      await dbHelper.insertOrUpdateScannedResults(
          scannedData); // Assuming you have a method for this
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Scanned results saved successfully')),
    );
  }

  Future<Map<String, dynamic>?> fetchMasterItem(String scannedCode) async {
    const url = 'http://108.136.252.63:8080/pogr/getmaster.php';
    const brand = 'YEC';

    try {
      var request = http.MultipartRequest('POST', Uri.parse(url));
      request.fields['ACTION'] = 'GETITEM';
      request.fields['BRAND'] = brand;
      request.fields['BARCODE'] = scannedCode;

      var response = await request.send();

      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var jsonResponse = json.decode(responseData);

        if (jsonResponse['code'] == '1' && jsonResponse['msg'] is List) {
          List<dynamic> itemList = jsonResponse['msg'];
          if (itemList.isNotEmpty) {
            var item = itemList.first as Map<String, dynamic>;
            item['scandate'] = DateTime.now(); // Tambahkan scandate
            return item;
          }
        }
      }
      return null;
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
                  int poQty = int.tryParse((item['QTYPO'] as String)
                          .replaceAll(formatQTYRegex, '')) ??
                      0;
                  int scannedQty =
                      int.tryParse(item['QTYS']?.toString() ?? '0') ?? 0;
                  int newScannedQty = scannedQty + inputQty;

                  bool isLargerThanQTYPO = newScannedQty > poQty;

                  item['QTYS'] = isLargerThanQTYPO ? poQty : newScannedQty;
                  item['QTYD'] =
                      isLargerThanQTYPO ? (poQty - newScannedQty).abs() : 0;

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
        item, (po) => po['BARCODE'] == item["BARCODE"]);
    setState(() {});
    savePOToRecent(_poNumberController.text);
    submitDataToDatabase();
  }

  Future<void> savePOToRecent(String updatedPONO) async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? recentNoPOs = prefs.getStringList('recent_pos') ?? [];

    recentNoPOs =
        recentNoPOs.replaceOrAdd(updatedPONO, (pono) => pono == updatedPONO);
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
                            const Center(
                                child: Text('Search for a PO to see details'))
                          else
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
                                      DataColumn(label: Text('Qty Scan')),
                                    ],
                                    rows: detailPOData
                                        .map(
                                          (e) => DataRow(
                                            cells: [
                                              DataCell(Text(
                                                  e['ITEMSKU']?.toString() ??
                                                      '')),
                                              DataCell(Text(e['ITEMSKUNAME']
                                                      ?.toString() ??
                                                  '')),
                                              DataCell(Text(
                                                  e['BARCODE']?.toString() ??
                                                      '')),
                                              DataCell(Text(
                                                  (e['QTYPO'] as String)
                                                      .replaceAll(
                                                          formatQTYRegex, ''))),
                                              DataCell(Text(
                                                  (e['QTYS'] ?? 0).toString())),
                                            ],
                                          ),
                                        )
                                        .toList(),
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(height: 20),
                          Expanded(
                            child: Column(
                              children: [
                                const Text(
                                  'Scanned Results',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold),
                                ),
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: SingleChildScrollView(
                                      controller: ScrollController(),
                                      child: DataTable(
                                        columns: const [
                                          DataColumn(label: Text('PO Number')),
                                          DataColumn(label: Text('Item SKU')),
                                          DataColumn(label: Text('Item Name')),
                                          DataColumn(label: Text('Barcode')),
                                          DataColumn(
                                              label: Text('Qty Scanned')),
                                          DataColumn(label: Text('User')),
                                          DataColumn(label: Text('Device')),
                                          DataColumn(label: Text('Timestamp')),
                                        ],
                                        rows: scannedResults
                                            .map(
                                              (result) => DataRow(
                                                cells: [
                                                  DataCell(Text(
                                                      result['pono'] ?? '')),
                                                  DataCell(Text(
                                                      result['item_sku'] ??
                                                          '')),
                                                  DataCell(Text(
                                                      result['item_name'] ??
                                                          '')),
                                                  DataCell(Text(
                                                      result['barcode'] ?? '')),
                                                  DataCell(Text(
                                                      result['qty_scanned']
                                                          .toString())),
                                                  DataCell(Text(
                                                      result['user'] ?? '')),
                                                  DataCell(Text(
                                                      result['device_name'] ??
                                                          '')),
                                                  DataCell(Text(
                                                      result['scandate'] ??
                                                          '')),
                                                ],
                                              ),
                                            )
                                            .toList(),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  if (_poNumberController.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Please enter a PO number before scanning.')),
                    );
                    return;
                  }

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
        ));
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
