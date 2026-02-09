# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Flutter Downloader & Video Player
-keep class vn.hunghd.flutterdownloader.** { *; }
-keep class io.flutter.plugins.videoplayer.** { *; }

# Prevent R8 from stripping vital generated classes
-keep class com.example.hello_world.** { *; }
-dontwarn io.flutter.embedding.**
-ignorewarnings