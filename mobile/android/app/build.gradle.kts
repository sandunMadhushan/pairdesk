plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "me.madhushan.pairdesk"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "me.madhushan.pairdesk"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 23) // flutter_secure_storage needs 23
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing. The release workflow sets these from GitHub secrets:
    //   PAIRDESK_KEYSTORE (path to the .jks), PAIRDESK_KEYSTORE_PASSWORD,
    //   PAIRDESK_KEY_ALIAS, PAIRDESK_KEY_PASSWORD.
    // PAIRDESK_UNSIGNED=1 builds an unsigned APK (F-Droid signs its own).
    // Otherwise release builds use the debug key, so `flutter run --release` works.
    val keystore = System.getenv("PAIRDESK_KEYSTORE")
    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = System.getenv("PAIRDESK_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("PAIRDESK_KEY_ALIAS")
                keyPassword = System.getenv("PAIRDESK_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = when {
                System.getenv("PAIRDESK_UNSIGNED") == "1" -> null
                keystore != null -> signingConfigs.getByName("release")
                else -> signingConfigs.getByName("debug")
            }
        }
    }

    // No Google-encrypted dependency list in the APK (F-Droid rejects it).
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
