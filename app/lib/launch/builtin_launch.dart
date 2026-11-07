// 随包带的开屏动画：assets/boot/ 里四段小鲸鱼娘短片（720×1600、无声、8–18 秒），冷启动随机
// 播一段，走的就是用户自己选的启动画面那条路（lib/launch/launch_state.dart → LaunchMedia）。
//
// 视频和各自的首帧第一次用时复制到 `<app support>/launch/system/`，之后直接读文件：启动
// 路径上只查一次版本号和目录，冷启动不多等。开关在 shared_preferences 的 `launch_boot_anime`
// （默认开）；上一回播的那一段记在 `launch_boot_last`，下一回不会再抽到它。
//
// 素材由 tool/make-boot-clips.sh 从宿主的 boot-videos 裁成竖屏（原素材 16:9，手机 9:20，
// 铺满只留中间），第 4 段观感不好，没有带进来。

import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'custom_launch.dart';

/// 包里的一段。
class BuiltinClip {
  const BuiltinClip(this.id, this.milliseconds);

  /// 素材名（`assets/boot/<id>.mp4`，首帧 `<id>.jpg`）。
  final String id;

  /// 长度：只用来认「播放器卡住了」和「这段本来就长」。
  final int milliseconds;
}

/// 包里的开屏动画。
abstract final class BuiltinLaunch {
  /// 四段，按片名排。
  static const clips = [
    BuiltinClip('1', 8064),
    BuiltinClip('2', 15104),
    BuiltinClip('3', 12417),
    BuiltinClip('5', 18089),
  ];

  /// 包里它们的位置（pubspec 的 assets/boot/）。
  static const assetPrefix = 'assets/boot';

  /// 素材换了版本就加一：手机上旧的副本会被新的替掉。
  /// v2：四段都带上了原声（「欢迎回来」那句），之前是静音压的。
  static const version = 2;

  /// 开着（冷启动随机播一段）；默认开。
  static const onKey = 'launch_boot_anime';

  /// 上一回播的那一段。
  static const lastKey = 'launch_boot_last';

  /// 手机上的副本是哪一版素材。
  static const assetsKey = 'launch_boot_assets';

  /// 素材本身的大小（竖屏 9:20）。
  static const width = 720;
  static const height = 1600;

  /// 设置里的开关。
  static Future<bool> isOn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(onKey) ?? true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setOn(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(onKey, on);
  }

  /// 这次冷启动要播的那一段；null：关着，或者素材没读出来（那就走原来的默认动画）。
  static Future<CustomLaunch?> pick() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(onKey) == false) return null;
      final dir = await _copies(prefs);
      if (dir == null) return null;
      final last = prefs.getString(lastKey);
      final pool = [
        for (final clip in clips)
          if (clip.id != last) clip,
      ];
      if (pool.isEmpty) return null;
      final clip = pool[Random().nextInt(pool.length)];
      final path = '${dir.path}/${clip.id}.mp4';
      final poster = '${dir.path}/${clip.id}.jpg';
      if (!File(path).existsSync() || !File(poster).existsSync()) return null;
      await prefs.setString(lastKey, clip.id);
      return CustomLaunch(
        kind: LaunchMediaKind.video,
        path: path,
        poster: poster,
        width: width,
        height: height,
        durationMs: clip.milliseconds,
        bytes: File(path).lengthSync(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 手机上的副本：第一次（或素材换了版本）从包里解出来，之后原样返回。
  static Future<Directory?> _copies(SharedPreferences prefs) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/launch/system');
    if (prefs.getInt(assetsKey) == version && _complete(dir)) return dir;
    await dir.create(recursive: true);
    for (final clip in clips) {
      for (final ext in const ['mp4', 'jpg']) {
        final data = await rootBundle.load('$assetPrefix/${clip.id}.$ext');
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        await File('${dir.path}/${clip.id}.$ext').writeAsBytes(bytes, flush: true);
      }
    }
    await prefs.setInt(assetsKey, version);
    return dir;
  }

  static bool _complete(Directory dir) {
    for (final clip in clips) {
      if (!File('${dir.path}/${clip.id}.mp4').existsSync()) return false;
      if (!File('${dir.path}/${clip.id}.jpg').existsSync()) return false;
    }
    return true;
  }
}
