package com.max.keykeep_passwords;

final class VaultBridge {
    static { System.loadLibrary("keykeep"); }
    static native long open(byte[] path);
    static native byte[] request(long handle, byte[] request);
    static native byte[] authenticatedPin(long handle);
    static native boolean erasing(long handle);
    static native boolean initializeDevice(long handle, byte[] key);
    static native boolean finishErasure(long handle, byte[] key);
    static native long mcpSignal(long handle);
    static native void waitSignal(long signal);
    static native void close(long handle);
}
