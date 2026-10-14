import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingProperties = Properties()
val signingFile = rootProject.file("key.properties")
if (signingFile.exists()) {
    FileInputStream(signingFile).use { signingProperties.load(it) }
}
fun signingValue(key: String, environment: String): String? =
    System.getenv(environment)?.takeIf { it.isNotBlank() }
        ?: signingProperties.getProperty(key)?.takeIf { it.isNotBlank() }
val releaseStore = signingValue("storeFile", "SILLYDRAFT_KEYSTORE")
val releaseStorePassword = signingValue("storePassword", "SILLYDRAFT_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "SILLYDRAFT_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "SILLYDRAFT_KEY_PASSWORD")
val hasReleaseSigning = listOf(releaseStore, releaseStorePassword, releaseKeyAlias, releaseKeyPassword).all { it != null }
val developmentSigning = System.getenv("SILLYDRAFT_DEVELOPMENT_SIGNING") == "true"
if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) } && !hasReleaseSigning && !developmentSigning) {
    throw GradleException("Configure android/key.properties or SILLYDRAFT signing environment variables. For local verification only, set SILLYDRAFT_DEVELOPMENT_SIGNING=true.")
}

android {
    namespace = "com.moonrailgun.sillydraft"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.moonrailgun.sillydraft"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStore!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = when {
                hasReleaseSigning -> signingConfigs.getByName("release")
                developmentSigning -> signingConfigs.getByName("debug")
                else -> null
            }
        }
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
