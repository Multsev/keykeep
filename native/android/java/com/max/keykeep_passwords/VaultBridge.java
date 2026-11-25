package com.max.keykeep_passwords;

final class VaultBridge {
    static { System.loadLibrary("keykeep"); }
    static native long open(byte[] path, byte[] deviceKey);
    static native byte[] request(long handle, byte[] request);
    static native byte[] authenticatedPin(long handle);
    static native void close(long handle);
}
