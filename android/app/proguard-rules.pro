# vodozemac/Olm sont du Rust via FFI : garder les classes JNI et le SDK Matrix intacts.
-keep class org.matrix.** { *; }
-keep class uniffi.** { *; }
-keep class fr.lansight.murmure.** { *; }

# SQLCipher
-keep class net.zetetic.database.** { *; }

# flutter_blue_plus
-keep class com.lib.flutter_blue_plus.** { *; }

-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
