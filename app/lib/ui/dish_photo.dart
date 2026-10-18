import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 菜品图片：没有图时显示首字 + 渐变色块
///
/// 菜单里大量菜品没有照片，用"首字色块"比统一占位图更好认。
class DishPhoto extends StatelessWidget {
  const DishPhoto({
    super.key,
    required this.url,
    required this.name,
    this.radius = 0,
    this.iconOnly = false,
  });

  final String url;
  final String name;
  final double radius;
  final bool iconOnly;

  static const _palette = [
    Color(0xFFE8623C),
    Color(0xFFD9A032),
    Color(0xFF5B8C5A),
    Color(0xFF3F7E8C),
    Color(0xFF8C5B7E),
    Color(0xFF7E6A3F),
  ];

  Color get _tint {
    if (name.isEmpty) return _palette.first;
    final code = name.codeUnits.fold<int>(0, (a, b) => a + b);
    return _palette[code % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _placeholder();

    final img = CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 180),
      placeholder: (c, _) => Container(color: _tint.withValues(alpha: 0.10)),
      errorWidget: (c, _, __) => _placeholder(),
    );

    return radius > 0
        ? ClipRRect(borderRadius: BorderRadius.circular(radius), child: img)
        : img;
  }

  Widget _placeholder() {
    final tint = _tint;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [tint.withValues(alpha: 0.18), tint.withValues(alpha: 0.08)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: iconOnly || name.isEmpty
          ? Icon(Icons.local_dining_outlined, size: 24, color: tint.withValues(alpha: 0.75))
          : Text(
              name.substring(0, 1),
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: tint.withValues(alpha: 0.62),
              ),
            ),
    );
  }
}
