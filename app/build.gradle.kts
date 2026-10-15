import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

android {
    namespace = "app.entesaver"
    compileSdk = 36

    defaultConfig {
        // The application ID (the package name): the app's identity on every
        // phone and in Android's eyes. It can never change again: a different
        // application ID is a different app - it would not install over this
        // one, and everything the app knows would stay behind. Only Android
        // sees it; people see the name. (Until 12.2 it was app.cloudsaver,
        // which 12.3 replaced once, with the name.)
        applicationId = "app.entesaver"
        minSdk = 29
        targetSdk = 36
        // Semantic version, and a versionCode derived from it rather than
        // hand-incremented: major*10000 + minor*100 + patch. It is always
        // monotonic, it never collides across branches, and it leaves room
        // for 99 minors and 99 patches without ever needing a reset.
        //   3.0.0 -> 30000
        versionName = "12.3.4"
        versionCode = versionName!!.split(".").let { (major, minor, patch) ->
            major.toInt() * 10_000 + minor.toInt() * 100 + patch.toInt()
        }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Tamper evidence: CI passes -PsigningCertSha256=<sha256 of the release
        // signing cert> before building; empty (dev builds) disables the check.
        val certSha = (project.findProperty("signingCertSha256") as? String).orEmpty()
        buildConfigField("String", "EXPECTED_CERT_SHA256", "\"$certSha\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = false
        // The app ships one language on purpose (13.F), so there is nothing to
        // translate and nothing to fall out of sync; these stay warnings rather
        // than gates in case a stray qualifier folder is ever added.
        warning += setOf("MissingTranslation", "ExtraTranslation")
        disable += setOf("AndroidGradlePluginVersion", "GradleDependency", "NewerVersionAvailable")
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    androidResources {
        // The app ships one language on purpose (13.F). The libraries under
        // it ship ninety; this keeps their translations out of the APK, so
        // the file says what the About page says.
        localeFilters += "en"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.core)
    // Settings rows each carry a leading glyph. R8 keeps only the icons that
    // are actually referenced, so the shipped dex grows by those alone.
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.room.runtime)
    ksp(libs.androidx.room.compiler)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.exifinterface)
    implementation(libs.androidx.heifwriter)
    implementation(libs.androidx.biometric)
    implementation(libs.media3.transformer)
    implementation(libs.media3.effect)
    implementation(libs.media3.common)

    testImplementation(libs.junit)
    testImplementation(libs.org.json)
    // Instrumented end-to-end suite: runs on a real emulator in CI.
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.espresso.core)
    androidTestImplementation(libs.uiautomator)
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}

// Many of this project's rules are source-text rules: they open repository
// files and assert properties of the words in them - that no chip repeats
// another, that the About card names every permission the manifest holds,
// that the repository holds no document and no key, that the CI workflow
// never publishes a private key.
//
// Gradle knew about none of those files. Editing strings.xml and re-running
// the tests reported `testDebugUnitTest UP-TO-DATE` and replayed the previous
// verdict, so a copy rule could pass over text it had never read - which is
// exactly how the first proof of two new rules "passed" while the fault sat
// in the file. CI is not safe by accident either: the build cache is on in
// gradle.properties and the Gradle action restores it, so a commit that
// only touches a file no rule declared could replay the previous verdict.
//
// Declared here so every run tells the truth. If a rule reads a file as
// text, that file - or its directory - belongs in this list.
tasks.withType<Test>().configureEach {
    inputs.files(
        rootProject.file("gradle/wrapper/gradle-wrapper.properties"),
        file("src/main/AndroidManifest.xml")
    )
        .withPathSensitivity(PathSensitivity.RELATIVE)
        .withPropertyName("sourceTextRuleFiles")
    // One rule asserts the repository holds no document and no key. It reads
    // the git index rather than the disk, which Gradle cannot hash - so the
    // files that would break it are the declared input instead. Empty today;
    // anything that breaks the rule re-runs it by existing.
    inputs.files(
        rootProject.fileTree(".") {
            include("**/*.md", "**/*.jks", "**/*.keystore", "**/*.p12", "**/*.pfx", "**/*.pem")
            exclude("**/build/**", "**/.git/**", "**/.gradle/**", "**/.kotlin/**")
        }
    )
        .withPathSensitivity(PathSensitivity.RELATIVE)
        .withPropertyName("filesThatShouldNotBeInTheRepository")
    inputs.dir(rootProject.file(".github/workflows"))
        .withPathSensitivity(PathSensitivity.RELATIVE)
        .withPropertyName("sourceTextRuleWorkflows")
    inputs.dir(rootProject.file(".github/scripts"))
        .withPathSensitivity(PathSensitivity.RELATIVE)
        .withPropertyName("sourceTextRuleScripts")
    // The naming rule reads every file git tracks, wherever it sits: a list
    // of named files kept missing the next one (gradle.properties, gradlew,
    // a new LICENSE), and a commit touching only that file replayed the
    // last pass from the cache. So the whole working tree is the input,
    // less what git ignores and what only builds or tools write. Not the
    // git index: it holds per-checkout timestamps and would never cache.
    inputs.files(
        rootProject.fileTree(".") {
            exclude(
                ".git", ".git/**", "**/build/**", "**/.gradle/**", "**/.kotlin/**", ".idea/**",
                ".claude/worktrees/**", "artifacts/**", "captures/**", "app/release/**",
                "app/schemas/**", "**/.cxx/**", "**/.externalNativeBuild/**", "local.properties",
                "**/*.iml", "**/.DS_Store", "**/*.jks", "**/*.keystore"
            )
        }
    )
        .withPathSensitivity(PathSensitivity.RELATIVE)
        .withPropertyName("sourceTextRuleRepositoryTree")
    inputs.dir(file("src/main/kotlin"))
        .withPathSensitivity(PathSensitivity.RELATIVE)
        .withPropertyName("sourceTextRuleSources")
    inputs.dir(file("src/main/res"))
        .withPathSensitivity(PathSensitivity.RELATIVE)
        .withPropertyName("sourceTextRuleResources")
    inputs.dir(file("src/androidTest"))
        .withPathSensitivity(PathSensitivity.RELATIVE)
        .withPropertyName("sourceTextRuleInstrumented")
}

// CI helper: prints the app version name.
tasks.register("printVersionName") {
    val versionName = android.defaultConfig.versionName
    doLast { println(versionName) }
}
