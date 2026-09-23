import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

import 'prebuilt.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    if (![
      OS.windows,
      OS.linux,
      OS.macOS,
      OS.iOS,
      OS.android,
    ].contains(code.targetOS)) {
      throw UnsupportedError(
        'ech_http supports Android, iOS, Linux, macOS, and Windows',
      );
    }
    final root = input.packageRoot.toFilePath();
    final out = input.outputDirectory.toFilePath();
    final shared = input.outputDirectoryShared.toFilePath();
    final cache =
        input.userDefines.path('binary_cache')?.toFilePath() ??
        input.userDefines.path('source_cache')?.toFilePath() ??
        p.join(shared, 'prebuilt');
    await Directory(out).create(recursive: true);
    final runner = _Runner(p.join(out, 'native-build.log'));
    final manifestPath = p.join(root, 'hook', 'dependencies.json');
    final manifest =
        jsonDecode(await File(manifestPath).readAsString())
            as Map<String, dynamic>;
    output.dependencies.addAll([
      Uri.file(manifestPath),
      Uri.file(p.join(root, 'hook', 'prebuilt.dart')),
    ]);
    await for (final file in Directory(
      p.join(root, 'src'),
    ).list(recursive: true)) {
      if (file is File) output.dependencies.add(file.uri);
    }
    final target = dependencyTarget(
      code.targetOS,
      code.targetArchitecture,
      iosSdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
    );
    final dependency = PrebuiltDependency.fromManifest(manifest, target);
    final sdk = await preparePrebuilt(dependency, cache);

    final tools = await _toolchain(code, runner);
    runner.environment = tools.environment;
    final common = <String>[
      '-G',
      'Ninja',
      '-DCMAKE_MAKE_PROGRAM=${tools.ninja}',
      '-DCMAKE_BUILD_TYPE=Release',
      '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
      '-DCMAKE_C_VISIBILITY_PRESET=hidden',
      '-DCMAKE_CXX_VISIBILITY_PRESET=hidden',
      '-DCMAKE_VISIBILITY_INLINES_HIDDEN=ON',
      ...tools.arguments,
    ];
    final parallel = '${math.min(Platform.numberOfProcessors, 8)}';
    final nativeBuild = p.join(out, 'native');
    stderr.writeln(
      'ech_http: compiling C++ bridge with prebuilt $target dependencies',
    );
    await runner.run(tools.cmake, [
      '-S',
      p.join(root, 'src'),
      '-B',
      nativeBuild,
      ...common,
      '-DEH_DEPS_ROOT=$sdk',
    ]);
    await runner.run(tools.cmake, [
      '--build',
      nativeBuild,
      '--target',
      'ech_http',
      '--parallel',
      parallel,
    ]);
    final filename = code.targetOS == OS.windows
        ? 'ech_http.dll'
        : (code.targetOS == OS.macOS || code.targetOS == OS.iOS
              ? 'libech_http.dylib'
              : 'libech_http.so');
    final library = File(p.join(nativeBuild, 'out', filename));
    if (!await library.exists()) {
      throw StateError('Native build did not produce ${library.path}');
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'ech_http_bindings',
        linkMode: DynamicLoadingBundled(),
        file: library.uri,
      ),
    );
  });
}

final class _Tools {
  _Tools(this.cmake, this.ninja, this.environment, this.arguments);
  final String cmake, ninja;
  final Map<String, String> environment;
  final List<String> arguments;
}

Future<_Tools> _toolchain(CodeConfig code, _Runner runner) async {
  var environment = Map<String, String>.of(Platform.environment);
  final arguments = <String>[];
  if (code.targetOS == OS.windows && !Platform.isWindows) {
    throw UnsupportedError('Windows targets require a Windows host with MSVC');
  }
  String? visualStudio;
  if (Platform.isWindows) {
    final vswhere = p.join(
      Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
      'Microsoft Visual Studio',
      'Installer',
      'vswhere.exe',
    );
    if (await File(vswhere).exists()) {
      final result = await Process.run(vswhere, [
        '-latest',
        '-products',
        '*',
        '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property',
        'installationPath',
      ]);
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        visualStudio = result.stdout.toString().trim().split('\n').first.trim();
      }
    }
    if (code.targetOS == OS.windows) {
      if (visualStudio == null) {
        throw StateError('Install Visual Studio C++ build tools');
      }
      final arch = switch (code.targetArchitecture) {
        Architecture.x64 => 'x64',
        Architecture.arm64 => 'arm64',
        Architecture.ia32 => 'x86',
        _ => throw UnsupportedError(
          'Windows architecture ${code.targetArchitecture}',
        ),
      };
      final script = p.join(visualStudio, 'Common7', 'Tools', 'VsDevCmd.bat');
      final capture = File(
        p.join(p.dirname(runner.logPath), 'compiler_environment.cmd'),
      );
      await capture.writeAsString(
        '@echo off\r\ncall "${script.replaceAll('%', '%%')}" -no_logo -host_arch=x64 -arch=$arch >nul\r\nif errorlevel 1 exit /b 1\r\nset\r\n',
      );
      final setup = await Process.run(capture.path, [], runInShell: true);
      if (setup.exitCode != 0) {
        throw StateError(
          'Visual Studio environment setup failed: ${setup.stderr}',
        );
      }
      environment = {};
      for (final line in const LineSplitter().convert(
        setup.stdout.toString(),
      )) {
        final index = line.indexOf('=');
        if (index > 0) {
          environment[line.substring(0, index)] = line.substring(index + 1);
        }
      }
      arguments.add('-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded');
    }
  }
  var cmake = _onPath('cmake', environment);
  var ninja = _onPath('ninja', environment);
  if (visualStudio != null) {
    cmake ??= _existing(
      p.join(
        visualStudio,
        'Common7',
        'IDE',
        'CommonExtensions',
        'Microsoft',
        'CMake',
        'CMake',
        'bin',
        'cmake.exe',
      ),
    );
    ninja ??= _existing(
      p.join(
        visualStudio,
        'Common7',
        'IDE',
        'CommonExtensions',
        'Microsoft',
        'CMake',
        'Ninja',
        'ninja.exe',
      ),
    );
  }
  final androidSdk =
      environment['ANDROID_SDK_ROOT'] ?? environment['ANDROID_HOME'];
  if ((cmake == null || ninja == null) && androidSdk != null) {
    final dir = Directory(p.join(androidSdk, 'cmake'));
    if (dir.existsSync()) {
      final versions = dir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final version in versions) {
        cmake ??= _existing(
          p.join(
            version.path,
            'bin',
            Platform.isWindows ? 'cmake.exe' : 'cmake',
          ),
        );
        ninja ??= _existing(
          p.join(
            version.path,
            'bin',
            Platform.isWindows ? 'ninja.exe' : 'ninja',
          ),
        );
      }
    }
  }
  if (cmake == null || ninja == null) {
    throw StateError(
      'ech_http requires CMake >=3.22 and Ninja on PATH (or installed with Visual Studio/Android SDK)',
    );
  }
  if (code.targetOS == OS.android) {
    String? ndk =
        environment['ANDROID_NDK_HOME'] ?? environment['ANDROID_NDK_ROOT'];
    final compiler = code.cCompiler?.compiler.toFilePath();
    if (compiler != null) {
      final index = compiler.indexOf('${p.separator}toolchains${p.separator}');
      if (index >= 0) ndk = compiler.substring(0, index);
    }
    if (ndk == null && androidSdk != null) {
      final dir = Directory(p.join(androidSdk, 'ndk'));
      if (dir.existsSync()) {
        final versions = dir.listSync().whereType<Directory>().toList()
          ..sort((a, b) => b.path.compareTo(a.path));
        if (versions.isNotEmpty) ndk = versions.first.path;
      }
    }
    if (ndk == null) throw StateError('Android NDK not found');
    final abi = switch (code.targetArchitecture) {
      Architecture.arm64 => 'arm64-v8a',
      Architecture.arm => 'armeabi-v7a',
      Architecture.x64 => 'x86_64',
      Architecture.ia32 => 'x86',
      _ => throw UnsupportedError(
        'Android architecture ${code.targetArchitecture}',
      ),
    };
    arguments.addAll([
      '-DCMAKE_TOOLCHAIN_FILE=${p.join(ndk, 'build', 'cmake', 'android.toolchain.cmake')}',
      '-DANDROID_ABI=$abi',
      '-DANDROID_PLATFORM=android-${math.max(21, code.android.targetNdkApi)}',
      '-DANDROID_STL=c++_static',
    ]);
  } else if (code.targetOS == OS.macOS || code.targetOS == OS.iOS) {
    if (!Platform.isMacOS) {
      throw UnsupportedError('Apple targets require a macOS host with Xcode');
    }
    final arch = code.targetArchitecture == Architecture.arm64
        ? 'arm64'
        : code.targetArchitecture == Architecture.x64
        ? 'x86_64'
        : throw UnsupportedError(
            'Apple architecture ${code.targetArchitecture}',
          );
    arguments.add('-DCMAKE_OSX_ARCHITECTURES=$arch');
    if (code.targetOS == OS.iOS) {
      final sdk = code.iOS.targetSdk == IOSSdk.iPhoneOS
          ? 'iphoneos'
          : 'iphonesimulator';
      arguments.addAll([
        '-DCMAKE_SYSTEM_NAME=iOS',
        // Dependencies include CLI targets even when we only build libraries.
        // iOS defaults to app bundles, which breaks their install declarations.
        '-DCMAKE_MACOSX_BUNDLE=OFF',
        '-DCMAKE_OSX_SYSROOT=$sdk',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${math.max(13, code.iOS.targetVersion)}.0',
      ]);
    } else {
      final minimum = code.targetArchitecture == Architecture.arm64 ? 11 : 10;
      final version = math.max(minimum, code.macOS.targetVersion);
      arguments.add(
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${version <= 10 ? '10.15' : '$version.0'}',
      );
    }
  } else if (code.targetOS == OS.linux) {
    if (!Platform.isLinux) {
      throw UnsupportedError('Linux targets require a Linux host/toolchain');
    }
    final hostArchitecture = switch (Abi.current()) {
      Abi.linuxX64 => Architecture.x64,
      Abi.linuxArm64 => Architecture.arm64,
      _ => throw UnsupportedError(
        'Unsupported Linux host ABI ${Abi.current()}',
      ),
    };
    if (code.targetArchitecture != hostArchitecture) {
      throw UnsupportedError(
        'Build Linux ${code.targetArchitecture} on a matching Linux host',
      );
    }
    if (code.cCompiler != null) {
      arguments.add(
        '-DCMAKE_C_COMPILER=${code.cCompiler!.compiler.toFilePath()}',
      );
      final cc = code.cCompiler!.compiler.toFilePath();
      final cxx = cc.endsWith('clang')
          ? '$cc++'
          : cc.endsWith('gcc')
          ? '${cc.substring(0, cc.length - 3)}g++'
          : null;
      if (cxx != null && File(cxx).existsSync()) {
        arguments.add('-DCMAKE_CXX_COMPILER=$cxx');
      }
    }
  }
  return _Tools(cmake, ninja, environment, arguments);
}

String? _existing(String path) => File(path).existsSync() ? path : null;
String? _onPath(String name, Map<String, String> environment) {
  final path =
      environment.entries
          .where((e) => e.key.toLowerCase() == 'path')
          .map((e) => e.value)
          .firstOrNull ??
      '';
  for (final part in path.split(Platform.isWindows ? ';' : ':')) {
    final result = _existing(
      p.join(part, Platform.isWindows ? '$name.exe' : name),
    );
    if (result != null) return result;
  }
  return null;
}

final class _Runner {
  _Runner(this.logPath);
  final String logPath;
  Map<String, String>? environment;
  Future<void> run(String executable, List<String> args) async {
    final log = File(logPath).openWrite(mode: FileMode.append);
    log.writeln('\n> $executable ${args.join(' ')}');
    final process = await Process.start(
      executable,
      args,
      environment: {...?environment, 'GIT_TERMINAL_PROMPT': '0'},
    );
    final tail = <String>[];
    void collect(String line) {
      log.writeln(line);
      tail.add(line);
      if (tail.length > 50) tail.removeAt(0);
    }

    await Future.wait([
      process.stdout
          .transform(systemEncoding.decoder)
          .transform(const LineSplitter())
          .forEach(collect),
      process.stderr
          .transform(systemEncoding.decoder)
          .transform(const LineSplitter())
          .forEach(collect),
    ]);
    final exit = await process.exitCode;
    await log.close();
    if (exit != 0) {
      throw ProcessException(
        executable,
        args,
        '${tail.join('\n')}\nFull log: $logPath',
        exit,
      );
    }
  }
}
