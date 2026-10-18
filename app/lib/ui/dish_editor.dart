import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../core/problem.dart';
import '../state/app_state.dart';
import 'category_manager.dart';
import 'common.dart';
import 'dish_photo.dart';

/// 菜品编辑：新建 / 修改 / 下架 / 删除
class DishEditor extends StatefulWidget {
  const DishEditor({super.key, this.dish});

  /// null = 新建
  final Dish? dish;

  @override
  State<DishEditor> createState() => _DishEditorState();
}

class _DishEditorState extends State<DishEditor> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _note = TextEditingController();
  final _tagCtrl = TextEditingController();

  final List<String> _tags = [];
  String? _typeId;
  final Set<String> _flavorIds = {};
  bool _isAvailable = true;

  /// 本地选的新图（尚未上传）
  File? _pickedFile;
  /// 已有的 imageKey
  String? _imageKey;
  bool _uploading = false;
  bool _saving = false;

  bool get _isNew => widget.dish == null;

  @override
  void initState() {
    super.initState();
    final d = widget.dish;
    if (d != null) {
      _name.text = d.name;
      _note.text = d.note ?? '';
      _tags.addAll(d.tags);
      _typeId = d.typeId;
      _flavorIds.addAll(d.flavorIds);
      _isAvailable = d.isAvailable;
      _imageKey = d.imageKey;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  // ---------------- 图片 ----------------

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 92, // 真正压缩在 sync.compressAndUpload 里做，这里只防超大原图
      );
      if (picked == null) return;
      setState(() => _pickedFile = File(picked.path));
      await _uploadNow();
    } catch (e) {
      if (mounted) context.snack('选择图片失败：$e', error: true);
    }
  }

  Future<void> _uploadNow() async {
    final f = _pickedFile;
    if (f == null) return;
    setState(() => _uploading = true);
    final s = context.read<AppState>();
    try {
      final key = await s.uploadImage(f.path);
      if (!mounted) return;
      setState(() => _imageKey = key);
      context.snack('图片已上传');
    } on ApiProblem catch (e) {
      if (mounted) context.snack('上传失败：${e.friendly}', error: true);
    } catch (e) {
      if (mounted) context.snack('上传失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ---------------- 保存 ----------------

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_uploading) {
      context.snack('图片还在上传，稍等一下');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _saving = true);

    final s = context.read<AppState>();
    final name = _name.text.trim();
    final note = _note.text.trim();

    // 离线优先：先写本地 + 入队，联网后自动重放
    final id = _isNew ? const Uuid().v4() : widget.dish!.id;

    final local = Dish(
      id: id,
      name: name,
      imageKey: _imageKey,
      note: note.isEmpty ? null : note,
      tags: List.of(_tags),
      typeId: _typeId,
      typeName: _typeNameOf(s, _typeId),
      flavorIds: _flavorIds.toList(),
      flavorNames: _flavorIds.map((f) => _flavorNameOf(s, f)).whereType<String>().toList(),
      isAvailable: _isAvailable,
      version: widget.dish?.version ?? 1,
    );

    final payload = <String, dynamic>{
      'id': id,
      'name': name,
      'imageKey': _imageKey,
      if (note.isNotEmpty) 'note': note,
      'tags': _tags,
      'typeId': _typeId,
      'flavorIds': _flavorIds.toList(),
      'isAvailable': _isAvailable,
      if (!_isNew) 'version': widget.dish!.version,
    };

    try {
      if (_isNew) {
        await s.sync.createDishOffline(local, payload);
      } else {
        // PATCH 里 null 表示"清空"，undefined 表示"不改"。
        // Dart 侧用显式 key 表达：typeId 传 null 才是清空
        payload['typeId'] = _typeId;
        payload['note'] = note.isEmpty ? null : note;
        payload['imageKey'] = _imageKey;
        await s.sync.updateDishOffline(local, payload);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      context.snack(_isNew ? '已加入菜单' : '已保存');
    } catch (e) {
      if (mounted) context.snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _typeNameOf(AppState s, String? id) {
    if (id == null) return null;
    for (final t in s.types) {
      if ((t['id'] ?? '').toString() == id) return (t['name'] ?? '').toString();
    }
    return null;
  }

  String? _flavorNameOf(AppState s, String id) {
    for (final f in s.flavors) {
      if ((f['id'] ?? '').toString() == id) return (f['name'] ?? '').toString();
    }
    return null;
  }

  Future<void> _delete() async {
    final ok = await confirm(context,
        title: '删除「${widget.dish!.name}」？',
        body: '删除后另一边的菜单里也会消失，历史订单不受影响。',
        okText: '删除',
        danger: true);
    if (!ok || !mounted) return;

    final s = context.read<AppState>();
    setState(() => _saving = true);
    try {
      await s.sync.deleteDishOffline(widget.dish!.id);
      if (!mounted) return;
      Navigator.of(context).pop();
      context.snack('已删除');
    } catch (e) {
      if (mounted) context.snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleAvailable() async {
    final s = context.read<AppState>();
    final next = !_isAvailable;
    setState(() => _saving = true);
    try {
      await s.sync.updateDishOffline(
        Dish(
          id: widget.dish!.id,
          name: widget.dish!.name,
          imageKey: _imageKey,
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          tags: _tags,
          typeId: _typeId,
          flavorIds: _flavorIds.toList(),
          isAvailable: next,
          version: widget.dish!.version,
        ),
        {'version': widget.dish!.version, 'isAvailable': next},
      );
      if (!mounted) return;
      setState(() => _isAvailable = next);
      context.snack(next ? '已重新上架' : '已下架');
    } catch (e) {
      if (mounted) context.snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addTag([String? raw]) {
    final t = (raw ?? _tagCtrl.text).trim();
    if (t.isEmpty) return;
    if (_tags.length >= 10) {
      context.snack('标签最多 10 个', error: true);
      return;
    }
    if (t.length > 12) {
      context.snack('单个标签最多 12 字', error: true);
      return;
    }
    if (_tags.contains(t)) return;
    setState(() => _tags.add(t));
    _tagCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final frozen = s.isFrozen;

    // 图片预览：本地新选的优先，其次已有的
    final remoteUrl = _pickedFile == null && _imageKey != null ? s.api.mediaUrl(_imageKey) : '';

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '加一道菜' : (widget.dish?.name ?? '编辑')),
        actions: [
          if (!_isNew)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'delete') _delete();
                if (v == 'toggle') _toggleAvailable();
              },
              itemBuilder: (c) => [
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(_isAvailable ? '下架（暂时不让人点）' : '重新上架'),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('删除这道菜', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: frozen || _saving,
        child: Opacity(
          opacity: frozen ? 0.55 : 1,
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
              children: [
                if (frozen) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: scheme.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline, size: 16, color: scheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('解散申请处理中，菜单已冻结',
                              style: TextStyle(fontSize: 12.5, color: scheme.error)),
                        ),
                      ],
                    ),
                  ),
                ],

                // ---- 图片 ----
                _PhotoPicker(
                  pickedFile: _pickedFile,
                  remoteUrl: remoteUrl,
                  name: _name.text,
                  uploading: _uploading,
                  onTap: () => _showImageSheet(),
                  onRemove: () => setState(() {
                    _pickedFile = null;
                    _imageKey = null;
                  }),
                ),
                const SizedBox(height: 22),

                // ---- 菜名 ----
                TextFormField(
                  controller: _name,
                  maxLength: 40,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    labelText: '菜名',
                    hintText: '比如 番茄炒蛋',
                    counterText: '',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty ? '菜名不能为空' : null,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 20),

                // ---- 种类（单选）----
                _SectionLabel(
                  '种类',
                  hint: '单选',
                  trailing: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CategoryManager(kind: 'type')),
                    ),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 32),
                    ),
                    child: const Text('管理', style: TextStyle(fontSize: 12.5)),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Choice(
                      label: '不分类',
                      selected: _typeId == null,
                      onTap: () => setState(() => _typeId = null),
                    ),
                    for (final t in s.types)
                      _Choice(
                        label: (t['name'] ?? '').toString(),
                        selected: _typeId == (t['id'] ?? '').toString(),
                        onTap: () {
                          final id = (t['id'] ?? '').toString();
                          setState(() => _typeId = _typeId == id ? null : id);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 22),

                // ---- 口味（多选）----
                _SectionLabel(
                  '口味',
                  hint: '可多选',
                  trailing: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CategoryManager(kind: 'flavor')),
                    ),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 32),
                    ),
                    child: const Text('管理', style: TextStyle(fontSize: 12.5)),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final f in s.flavors)
                      _Choice(
                        label: (f['name'] ?? '').toString(),
                        selected: _flavorIds.contains((f['id'] ?? '').toString()),
                        onTap: () {
                          final id = (f['id'] ?? '').toString();
                          setState(() {
                            if (!_flavorIds.remove(id)) _flavorIds.add(id);
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 22),

                // ---- 标签 ----
                const _SectionLabel('标签', hint: '自由添加，最多 10 个'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in _tags)
                      Chip(
                        label: Text(t, style: const TextStyle(fontSize: 12.5)),
                        onDeleted: () => setState(() => _tags.remove(t)),
                        deleteIcon: const Icon(Icons.close, size: 15),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: scheme.primary.withValues(alpha: 0.07),
                        side: BorderSide.none,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _tagCtrl,
                        maxLength: 12,
                        decoration: const InputDecoration(
                          hintText: '输入标签后回车',
                          counterText: '',
                          isDense: true,
                        ),
                        onSubmitted: _addTag,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: _addTag,
                      icon: const Icon(Icons.add, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // ---- 备注 ----
                TextFormField(
                  controller: _note,
                  maxLength: 200,
                  maxLines: 3,
                  minLines: 2,
                  decoration: const InputDecoration(
                    labelText: '备注',
                    hintText: '做法、忌口、需要的食材…',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),

                // ---- 上架开关（新建时也有意义）----
                SwitchListTile.adaptive(
                  value: _isAvailable,
                  onChanged: (v) => setState(() => _isAvailable = v),
                  title: const Text('可点', style: TextStyle(fontSize: 14.5)),
                  subtitle: Text('关掉后这道菜还在菜单里，但对方点不了',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: scheme.primary,
                ),
                const SizedBox(height: 18),

                FilledButton(
                  onPressed: (_saving || frozen) ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(_isNew ? '加入菜单' : '保存'),
                ),
                const SizedBox(height: 10),
                Center(
                  child: Text('保存后另一边的 App 会立刻同步',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showImageSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(c);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.pop(c);
                _pickImage(ImageSource.gallery);
              },
            ),
            if (_imageKey != null || _pickedFile != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('移除图片'),
                onTap: () {
                  Navigator.pop(c);
                  setState(() {
                    _pickedFile = null;
                    _imageKey = null;
                  });
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ---------------- 图片选择块 ----------------

class _PhotoPicker extends StatelessWidget {
  const _PhotoPicker({
    required this.pickedFile,
    required this.remoteUrl,
    required this.name,
    required this.uploading,
    required this.onTap,
    required this.onRemove,
  });

  final File? pickedFile;
  final String remoteUrl;
  final String name;
  final bool uploading;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasImage = pickedFile != null || remoteUrl.isNotEmpty;

    return Center(
      child: GestureDetector(
        onTap: uploading ? null : onTap,
        child: Container(
          width: 168,
          height: 168,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: hasImage ? Colors.transparent : scheme.outlineVariant,
              width: 1.4,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (pickedFile != null)
                Image.file(pickedFile!, fit: BoxFit.cover)
              else if (remoteUrl.isNotEmpty)
                DishPhoto(url: remoteUrl, name: name)
              else
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_a_photo_outlined, size: 30, color: scheme.primary),
                    const SizedBox(height: 8),
                    Text('加张照片',
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
              if (uploading)
                Container(
                  color: Colors.black.withValues(alpha: 0.42),
                  alignment: Alignment.center,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white)),
                      SizedBox(height: 10),
                      Text('上传中…', style: TextStyle(fontSize: 12, color: Colors.white)),
                    ],
                  ),
                ),
              if (hasImage && !uploading)
                Positioned(
                  top: 6,
                  right: 6,
                  child: GestureDetector(
                    onTap: onRemove,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, size: 14, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- 小部件 ----------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.hint, this.trailing});
  final String text;
  final String? hint;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        if (hint != null) ...[
          const SizedBox(width: 6),
          Text(hint!, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? scheme.primary : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.8),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.white : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
