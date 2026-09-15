// Build du module Android du plugin — Kotlin DSL, bloc `plugins` déclaratif.
//
// Ce qui change par rapport à l'ancien android/build.gradle (Groovy) :
//
//  1. Plus de `buildscript { classpath(AGP) / classpath(KGP) }`. Le module du
//     plugin est un sous-projet du build de l'application (le plugin-loader de
//     Flutter fait l'`include`), donc les versions viennent du `pluginManagement`
//     de l'app. Redéclarer un classpath AGP ici épinglait une seconde version.
//  2. `plugins { id(...) }` au lieu de `apply plugin:`. L'application
//     impérative est dépréciée côté Flutter, et en Kotlin DSL c'est le bloc
//     `plugins` qui donne l'accès typé à l'extension `android { }`.
//  3. `dependencies { }` sort du bloc `android { }`, où il n'avait rien à
//     faire — il n'y fonctionnait que par délégation Groovy.
//
// Prérequis côté application : `settings.gradle.kts` déclare AGP et KGP dans
// son `pluginManagement` (c'est le cas du projet d'exemple).

plugins {
    id("com.android.library")
    // Si le build échoue sur « Unresolved reference: kotlin » ou sur des
    // sources Kotlin non compilées, c'est que le Kotlin Gradle Plugin n'est
    // pas appliqué par AGP sur ce module. Décommenter alors la ligne suivante
    // (la version vient du pluginManagement de l'application) :
    // id("org.jetbrains.kotlin.android")
}

group = "com.dev.gcimia.radio_service"
version = "1.0-SNAPSHOT"

android {
    namespace = "com.dev.gcimia.radio_service"

    compileSdk = 37

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    defaultConfig {
        minSdk = 24 // Android 7.0 — minimum recommandé
    }

    sourceSets {
        getByName("main") { java.srcDir("src/main/kotlin") }
        getByName("test") { java.srcDir("src/test/kotlin") }
    }

    testOptions {
        unitTests.all {
            it.useJUnitPlatform()
            it.testLogging {
                events("passed", "skipped", "failed", "standardOut", "standardError")
                showStandardStreams = true
            }
            it.outputs.upToDateWhen { false }
        }
    }
}

// jvmTarget au niveau racine, et non dans `android { kotlinOptions { } }` :
// c'est la forme imposée par la migration « built-in Kotlin » de Flutter.
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21
    }
}

dependencies {
    val media3Version = "1.11.1"

    // AndroidX Core — ContextCompat.startForegroundService(),
    // ServiceCompat.stopForeground() et autres API de compatibilité.
    implementation("androidx.core:core-ktx:1.19.0")

    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-exoplayer-hls:$media3Version")
    implementation("androidx.media3:media3-datasource:$media3Version")
    implementation("androidx.media3:media3-session:$media3Version")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.23.0")
}
