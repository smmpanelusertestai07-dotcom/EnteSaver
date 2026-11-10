# kotlinx.serialization: keep generated serializers of @Serializable classes.
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod
-keepclassmembers @kotlinx.serialization.Serializable class com.pocketide.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keepclasseswithmembers class com.pocketide.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.pocketide.**$$serializer { *; }

# OkHttp ships its own consumer rules; these cover optional TLS providers.
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**

# The details of an error the owner copies (StopNote) must read without this build's mapping
# file: classes and methods keep their names, with their line numbers. R8 still shrinks.
-dontobfuscate
-keepattributes SourceFile,LineNumberTable
