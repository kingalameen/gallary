import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_view/photo_view.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gallery',
      theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: const GalleryPage(),
    );
  }
}

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  List<AssetEntity> _deviceImages = [];
  List<String> _localImages = []; // file paths saved by editor
  Set<String> _hiddenIds = {}; // contains asset ids or local file paths
  bool _loading = true;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _hiddenIds = (_prefs!.getStringList('hidden') ?? []).toSet();
    _localImages = _prefs!.getStringList('local_images') ?? [];

    final permitted = await PhotoManager.requestPermissionExtend();
    if (!permitted.isAuth) {
      // show permission denied UI
      setState(() => _loading = false);
      return;
    }

    await _loadDeviceImages();
    setState(() => _loading = false);
  }

  Future<void> _loadDeviceImages() async {
    final albums = await PhotoManager.getAssetPathList(
        onlyAll: true, type: RequestType.image);
    if (albums.isEmpty) return;
    final recent = albums.first;
    final assets = await recent.getAssetListPaged(page: 0, size: 1000);
    setState(() => _deviceImages = assets);
  }

  List<_GridItem> get _allItems {
    final deviceItems = _deviceImages
        .where((a) => !_hiddenIds.contains(a.id))
        .map((a) => _GridItem.device(a))
        .toList();
    final localItems = _localImages
        .where((p) => !_hiddenIds.contains(p))
        .map((p) => _GridItem.local(p))
        .toList();
    return [...localItems, ...deviceItems];
  }

  Future<void> _toggleHide(_GridItem item) async {
    final id = item.key;
    setState(() {
      if (_hiddenIds.contains(id))
        _hiddenIds.remove(id);
      else
        _hiddenIds.add(id);
    });
    await _prefs!.setStringList('hidden', _hiddenIds.toList());
  }

  Future<void> _saveLocalImage(File file) async {
    final dir = await getApplicationDocumentsDirectory();
    final name = 'img_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final dest = File('${dir.path}/$name');
    await file.copy(dest.path);
    _localImages.insert(0, dest.path);
    await _prefs!.setStringList('local_images', _localImages);
    setState(() {});
  }

  void _openHidden() async {
    final hasPin = (_prefs!.getString('pin_hash') ?? '').isNotEmpty;
    if (!hasPin) {
      // ask to set a PIN first
      final set = await Navigator.push(
          context, MaterialPageRoute(builder: (_) => const SetPinPage()));
      if (set == true) return _openHidden();
      return;
    }

    final ok = await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const EnterPinPage()));
    if (ok == true) {
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => HiddenAlbumPage(
                  hiddenIds: _hiddenIds,
                  localImages: _localImages,
                  deviceImages: _deviceImages,
                  onUnhide: (id) async {
                    setState(() {
                      _hiddenIds.remove(id);
                    });
                    await _prefs!.setStringList('hidden', _hiddenIds.toList());
                  })));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gallery'),
        actions: [
          IconButton(
              onPressed: () async {
                await _loadDeviceImages();
              },
              icon: const Icon(Icons.refresh)),
          IconButton(onPressed: _openHidden, icon: const Icon(Icons.lock)),
          IconButton(
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => SettingsPage(onPinChanged: () {}))),
              icon: const Icon(Icons.settings)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _allItems.isEmpty
              ? const Center(child: Text('No images'))
              : GridView.builder(
                  padding: const EdgeInsets.all(6),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4),
                  itemCount: _allItems.length,
                  itemBuilder: (context, i) {
                    final item = _allItems[i];
                    return GestureDetector(
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ViewerPage(
                                  item: item,
                                  onEdited: (file) async {
                                    await _saveLocalImage(file);
                                  }))),
                      onLongPress: () async {
                        final res = await showModalBottomSheet(
                            context: context,
                            builder: (ctx) {
                              return SafeArea(
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                    ListTile(
                                        leading: const Icon(Icons.hide_source),
                                        title: const Text('Hide'),
                                        onTap: () {
                                          Navigator.pop(ctx, 'hide');
                                        }),
                                    ListTile(
                                        leading: const Icon(Icons.info),
                                        title: const Text('Info'),
                                        onTap: () {
                                          Navigator.pop(ctx, 'info');
                                        }),
                                  ]));
                            });
                        if (res == 'hide') await _toggleHide(item);
                        if (res == 'info') {
                          showDialog(
                              context: context,
                              builder: (_) => AlertDialog(
                                      title: const Text('Info'),
                                      content: Text(item.info),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('OK'))
                                      ]));
                        }
                      },
                      child: Hero(
                        tag: item.heroTag,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: item.buildThumb(),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          // import images from device to local (select one) - simple implementation: pick first device image
          if (_deviceImages.isNotEmpty) {
            final file = await _deviceImages.first.file;
            if (file != null) await _saveLocalImage(file);
          }
        },
        icon: const Icon(Icons.add_photo_alternate),
        label: const Text('Import'),
      ),
    );
  }
}

class _GridItem {
  final AssetEntity? asset;
  final String? localPath;
  _GridItem._({this.asset, this.localPath});
  factory _GridItem.device(AssetEntity a) => _GridItem._(asset: a);
  factory _GridItem.local(String p) => _GridItem._(localPath: p);
  String get key => asset?.id ?? localPath!;
  String get heroTag => key;
  String get info => asset != null
      ? 'Device asset id: ${asset!.id}\nSize: ${asset!.width}x${asset!.height}'
      : 'Local file: $localPath';

  Widget buildThumb() {
    if (asset != null) {
      return FutureBuilder<Uint8List?>(
          future: asset!.thumbnailDataWithSize(ThumbnailSize(200, 200)),
          builder: (context, snap) {
            final data = snap.data;
            if (data == null) return Container(color: Colors.grey[300]);
            return Image.memory(data, fit: BoxFit.cover);
          });
    } else {
      return Image.file(File(localPath!), fit: BoxFit.cover);
    }
  }
}

class ViewerPage extends StatefulWidget {
  final _GridItem item;
  final ValueChanged<File>? onEdited;
  const ViewerPage({required this.item, this.onEdited, super.key});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  File? _file;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.item.asset != null) {
      final file = await widget.item.asset!.file;
      setState(() {
        _file = file;
        _loading = false;
      });
    } else {
      setState(() {
        _file = File(widget.item.localPath!);
        _loading = false;
      });
    }
  }

  Future<void> _edit() async {
    if (_file == null) return;
    // Crop first using image_cropper
    final cropped = await ImageCropper().cropImage(
        sourcePath: _file!.path,
        compressFormat: ImageCompressFormat.jpg,
        uiSettings: [
          AndroidUiSettings(
              toolbarTitle: 'Crop',
              toolbarColor: Colors.indigo,
              toolbarWidgetColor: Colors.white),
          IOSUiSettings(title: 'Crop')
        ]);
    if (cropped == null) return;
    File edited = File(cropped.path);

    // Simple rotate/brightness UI
    final result = await Navigator.push<File?>(context,
        MaterialPageRoute(builder: (_) => SimpleEditorPage(file: edited)));
    if (result != null) {
      setState(() {
        _file = result;
      });
      if (widget.onEdited != null) widget.onEdited!(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(actions: [
        IconButton(icon: const Icon(Icons.edit), onPressed: _edit)
      ]),
      body: _loading || _file == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: Hero(
                  tag: widget.item.heroTag,
                  child: PhotoView(imageProvider: FileImage(_file!)))),
    );
  }
}

class SimpleEditorPage extends StatefulWidget {
  final File file;
  const SimpleEditorPage({required this.file, super.key});

  @override
  State<SimpleEditorPage> createState() => _SimpleEditorPageState();
}

class _SimpleEditorPageState extends State<SimpleEditorPage> {
  late img.Image _orig;
  late img.Image _working;
  double _brightness = 0.0;
  int _rotation = 0; // degrees
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    final bytes = await widget.file.readAsBytes();
    _orig = img.decodeImage(bytes)!;
    _working = img.copyResize(_orig, width: _orig.width); // copy
    setState(() => _loading = false);
  }

  void _applyPreview() {
    final temp = img.copyRotate(_orig, angle: _rotation.toDouble());
    img.adjustColor(temp, brightness: (_brightness * 100).toInt());
    _working = temp;
    setState(() {});
  }

  Future<File> _exportResult() async {
    final temp = img.copyRotate(_orig, angle: _rotation.toDouble());
    img.adjustColor(temp, brightness: (_brightness * 100).toInt());
    final jpg = img.encodeJpg(temp, quality: 90);
    final dir = await getTemporaryDirectory();
    final out =
        File('${dir.path}/edited_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await out.writeAsBytes(jpg);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit'), actions: [
        TextButton(
            onPressed: () async {
              final out = await _exportResult();
              Navigator.pop(context, out);
            },
            child: const Text('Done', style: TextStyle(color: Colors.white)))
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                  child: Center(
                      child: Image.memory(img.encodeJpg(_working),
                          fit: BoxFit.contain))),
              Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(children: [
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                              onPressed: () {
                                setState(() {
                                  _rotation = (_rotation - 90) % 360;
                                  _applyPreview();
                                });
                              },
                              icon: const Icon(Icons.rotate_left)),
                          IconButton(
                              onPressed: () {
                                setState(() {
                                  _rotation = (_rotation + 90) % 360;
                                  _applyPreview();
                                });
                              },
                              icon: const Icon(Icons.rotate_right)),
                          Text('Rotate'),
                        ]),
                    Row(children: [
                      const Text('Brightness'),
                      Expanded(
                          child: Slider(
                              value: _brightness,
                              min: -1,
                              max: 1,
                              onChanged: (v) {
                                setState(() {
                                  _brightness = v;
                                  _applyPreview();
                                });
                              }))
                    ])
                  ]))
            ]),
    );
  }
}

class HiddenAlbumPage extends StatelessWidget {
  final Set<String> hiddenIds;
  final List<String> localImages;
  final List<AssetEntity> deviceImages;
  final ValueChanged<String> onUnhide;
  const HiddenAlbumPage(
      {required this.hiddenIds,
      required this.localImages,
      required this.deviceImages,
      required this.onUnhide,
      super.key});

  @override
  Widget build(BuildContext context) {
    final items = <_GridItem>[];
    for (final p in localImages)
      if (hiddenIds.contains(p)) items.add(_GridItem.local(p));
    for (final d in deviceImages)
      if (hiddenIds.contains(d.id)) items.add(_GridItem.device(d));

    return Scaffold(
      appBar: AppBar(title: const Text('Hidden')),
      body: items.isEmpty
          ? const Center(child: Text('No hidden images'))
          : GridView.builder(
              padding: const EdgeInsets.all(6),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final it = items[i];
                return GestureDetector(
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => ViewerPage(item: it))),
                  onLongPress: () async {
                    final un = await showDialog(
                        context: context,
                        builder: (_) =>
                            AlertDialog(title: const Text('Unhide?'), actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Cancel')),
                              TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Unhide'))
                            ]));
                    if (un == true) onUnhide(it.key);
                  },
                  child: Hero(
                      tag: it.heroTag,
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: it.buildThumb())),
                );
              },
            ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final VoidCallback? onPinChanged;
  const SettingsPage({this.onPinChanged, super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _prefsFuture = SharedPreferences.getInstance();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: FutureBuilder<SharedPreferences>(
        future: _prefsFuture,
        builder: (context, snap) {
          if (!snap.hasData)
            return const Center(child: CircularProgressIndicator());
          final prefs = snap.data!;
          final hasPin = (prefs.getString('pin_hash') ?? '').isNotEmpty;
          return ListView(children: [
            ListTile(
                title: const Text('Set/Change 4-digit PIN'),
                subtitle:
                    hasPin ? const Text('PIN is set') : const Text('No PIN'),
                trailing: Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const SetPinPage()));
                  if (widget.onPinChanged != null) widget.onPinChanged!();
                }),
            ListTile(
                title: const Text('Clear hidden list'),
                onTap: () async {
                  await prefs.remove('hidden');
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Hidden cleared')));
                }),
          ]);
        },
      ),
    );
  }
}

class SetPinPage extends StatefulWidget {
  const SetPinPage({super.key});

  @override
  State<SetPinPage> createState() => _SetPinPageState();
}

class _SetPinPageState extends State<SetPinPage> {
  final _pinCtl = TextEditingController();
  final _confirmCtl = TextEditingController();
  String? _error;

  Future<void> _save() async {
    final pin = _pinCtl.text.trim();
    final conf = _confirmCtl.text.trim();
    if (pin.length != 4 || conf.length != 4) {
      setState(() => _error = 'PIN must be 4 digits');
      return;
    }
    if (pin != conf) {
      setState(() => _error = 'PINs do not match');
      return;
    }
    final hash = base64
        .encode(utf8.encode(pin)); // simple store, not secure but local-only
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pin_hash', hash);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set 4-digit PIN')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(children: [
          TextField(
              controller: _pinCtl,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(labelText: 'PIN')),
          TextField(
              controller: _confirmCtl,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(labelText: 'Confirm PIN')),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.all(8.0),
                child:
                    Text(_error!, style: const TextStyle(color: Colors.red))),
          ElevatedButton(onPressed: _save, child: const Text('Save PIN'))
        ]),
      ),
    );
  }
}

class EnterPinPage extends StatefulWidget {
  const EnterPinPage({super.key});

  @override
  State<EnterPinPage> createState() => _EnterPinPageState();
}

class _EnterPinPageState extends State<EnterPinPage> {
  final _ctl = TextEditingController();
  String? _error;

  Future<void> _verify() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('pin_hash') ?? '';
    final input = base64.encode(utf8.encode(_ctl.text.trim()));
    if (input == stored)
      Navigator.pop(context, true);
    else
      setState(() => _error = 'Incorrect PIN');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enter PIN')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(children: [
          TextField(
              controller: _ctl,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(labelText: 'PIN')),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.all(8.0),
                child:
                    Text(_error!, style: const TextStyle(color: Colors.red))),
          ElevatedButton(onPressed: _verify, child: const Text('Open'))
        ]),
      ),
    );
  }
}
