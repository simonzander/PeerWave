import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Apply Google Services plugin conditionally (only for release builds with Firebase)
// Debug builds don't need it since org.peerwave.client.debug is not registered in Firebase
if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }) {
    apply(plugin = "com.google.gms.google-services")
}

// Calculate version code from semantic version and build number
// Formula: (major * 1000000000) + (minor * 1000000) + (patch * 1000) + buildNumber
// Example: 1.2.1+1 -> (1*1000000000) + (2*1000000) + (1*1000) + 1 = 1002001001
// Allows: major (0-2147), minor (0-999), patch (0-999), build_number (0-999)
// Max versionCode: 2,147,483,647 (32-bit signed integer limit)
fun calculateVersionCode(versionName: String, buildNumber: Int): Int {
    val version = versionName.split(".")
    if (version.size != 3) {
        println("Warning: Invalid semantic version '$versionName', using version code $buildNumber")
        return buildNumber
    }
    
    val major = version[0].toIntOrNull() ?: 0
    val minor = version[1].toIntOrNull() ?: 0
    val patch = version[2].toIntOrNull() ?: 0
    
    val calculatedCode = (major * 1000000000) + (minor * 1000000) + (patch * 1000) + buildNumber
    println("Calculated version code: $calculatedCode from version $versionName+$buildNumber")
    return calculatedCode
}

// Load keystore properties
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "org.peerwave.client"
    compileSdk = 36  // Required by plugins (flutter_webrtc, livekit_client, etc.)
    // ndkVersion removed - not required for this project

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.peerwave.client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion  // Android 5.0 Lollipop
        targetSdk = 36  // Match compileSdk
        
        // Calculate version code from semantic version + build number
        // This ensures unique, incrementing version codes for Google Play
        val flutterVersionName = flutter.versionName ?: "1.0.0"
        val flutterBuildNumber = flutter.versionCode ?: 1
        versionCode = calculateVersionCode(flutterVersionName, flutterBuildNumber)
        versionName = flutterVersionName  // Display version without build number
        
        // Enable multidex for apps with many dependencies
        multiDexEnabled = true
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Import the Firebase BoM
    implementation(platform("com.google.firebase:firebase-bom:34.8.0"))

    // TODO: Add the dependencies for Firebase products you want to use
    // When using the BoM, don't specify versions in Firebase dependencies
    // https://firebase.google.com/docs/android/setup#available-libraries

    // Core library desugaring for Java 8+ APIs (required by flutter_local_notifications)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// Disable incremental compilation to fix cross-drive path issues
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    incremental = false
}
