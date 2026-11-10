import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.detekt)
    alias(libs.plugins.ktlint)
}

// Owner configuration comes from Gradle properties or the environment, never from the source.
fun config(name: String): String {
    val local = Properties().apply {
        val file = rootProject.file("local.properties")
        if (file.isFile) file.inputStream().use { load(it) }
    }
    return (project.findProperty(name) as String?)
        ?: System.getenv(name)
        ?: local.getProperty(name)
        ?: ""
}

fun quoted(value: String) = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

/** An extra jniLibs folder with PRoot for x86-64, for the end-to-end test on the Android emulator. */
val emulatorLibs: String = (project.findProperty("pocketide.emulatorLibs") as String?).orEmpty()

// The one number to raise for a release: the tag is pocketide-v<appVersion>. versionCode follows
// from it (major * 10000 + minor * 100 + patch), so a newer version always installs over the one
// before it, and 8.1.0 (80100) installs over 8.0.0 (80000). tools/gates/version.py checks both.
val appVersion = "9.5.0"

fun versionCodeOf(version: String): Int {
    val parts = version.split(".").map { it.toIntOrNull() ?: -1 }
    require(parts.size == 3 && parts.all { it in 0..99 }) { "The version $version is not <major>.<minor>.<patch>, each below 100" }
    val (major, minor, patch) = parts
    return major * 10000 + minor * 100 + patch
}

android {
    namespace = "com.pocketide"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.pocketide"
        minSdk = 29
        targetSdk = 36
        versionCode = versionCodeOf(appVersion)
        versionName = appVersion

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // PRoot, the one native program (PocketIDE's connection runs Google's gcloud with it), is
        // built for phones (arm64). The end-to-end test adds an x86-64 build for the Android
        // emulator with -Ppocketide.emulatorLibs=<folder of jniLibs>.
        ndk {
            abiFilters += "arm64-v8a"
            if (emulatorLibs.isNotEmpty()) abiFilters += "x86_64"
        }

        // Where the app's releases are published. CI passes the repository its release job
        // publishes to (tools/gates/workflow.py checks it); the fallback serves local builds only.
        buildConfigField("String", "RELEASES_REPO", quoted(config("POCKETIDE_RELEASES_REPO").ifEmpty { "smmpanelusertestai07-dotcom/EnteSaver" }))
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signed in CI with apksigner (v2 + v3), from the POCKETIDE_* secrets.
            signingConfig = null
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    sourceSets {
        getByName("main") {
            if (emulatorLibs.isNotEmpty()) jniLibs.srcDir(emulatorLibs)
        }
    }

    packaging {
        // PRoot and its loader are run from the app's native library folder, the one place Android
        // lets an app run programs of its own (W^X), so the libraries are extracted at install.
        jniLibs { useLegacyPackaging = true }
        resources {
            excludes += setOf(
                "/META-INF/{AL2.0,LGPL2.1}",
                "/META-INF/DEPENDENCIES",
                "/META-INF/LICENSE*",
                "/META-INF/NOTICE*",
                "/META-INF/*.kotlin_module",
                "/META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "plugin.properties",
                "about.html",
            )
        }
    }

    lint {
        abortOnError = true
        warningsAsErrors = true
        checkReleaseBuilds = true
        // The reviewed false positives, each with its reason.
        lintConfig = file("lint.xml")
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion")
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.isIncludeAndroidResources = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        freeCompilerArgs.addAll("-opt-in=kotlin.RequiresOptIn")
        allWarningsAsErrors.set(true)
    }
}

// Style and code-smell gates (plan §15). Their settings and baselines live in tools/quality/: the
// baselines hold what the code had when the gates arrived, so any new finding fails the build.
val quality = rootProject.layout.projectDirectory.dir("tools/quality")

detekt {
    buildUponDefaultConfig = true
    parallel = true
    config.setFrom(quality.file("detekt.yml"))
    baseline = quality.file("detekt-baseline.xml").asFile
    source.setFrom("src/main/java", "src/test/java", "src/androidTest/java")
}

// detekt 1.23 runs on the Kotlin compiler it was built with, not the one this build uses.
configurations.matching { it.name == "detekt" }.configureEach {
    resolutionStrategy.eachDependency {
        if (requested.group == "org.jetbrains.kotlin") {
            useVersion(io.gitlab.arturbosch.detekt.getSupportedKotlinVersion())
        }
    }
}

ktlint {
    version.set(libs.versions.ktlint)
    baseline.set(quality.file("ktlint-baseline.xml"))
    // The house style: IntelliJ's Kotlin style (kotlin.code.style=official) with the compact
    // one-line signatures, calls and when branches the code base is written in.
    additionalEditorconfig.set(
        mapOf(
            "ktlint_code_style" to "intellij_idea",
            "max_line_length" to "160",
            "ktlint_function_naming_ignore_when_annotated_with" to "Composable",
            "ktlint_standard_argument-list-wrapping" to "disabled",
            "ktlint_standard_function-signature" to "disabled",
            "ktlint_standard_class-signature" to "disabled",
            "ktlint_standard_blank-line-between-when-conditions" to "disabled",
            "ktlint_standard_statement-wrapping" to "disabled",
        ),
    )
    filter { exclude { it.file.path.contains("/build/") } }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.lifecycle.service)
    implementation(libs.androidx.webkit)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.biometric)
    implementation(libs.androidx.fragment)
    implementation(libs.androidx.browser)
    implementation(libs.okhttp)
    implementation(libs.haze)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)

    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}

tasks.register("printVersionName") {
    val name = android.defaultConfig.versionName
    doLast { println(name) }
}
