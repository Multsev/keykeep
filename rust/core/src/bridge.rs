//! The native UI owns exactly one session and serializes all calls on its main thread.
use crate::session::Session;
use serde_json::json;
use std::{
    ffi::{CStr, CString, c_char},
    ptr,
};

#[unsafe(no_mangle)]
unsafe extern "C" fn kk_new(path: *const c_char, device: *const u8) -> *mut Session {
    if path.is_null() || device.is_null() {
        return ptr::null_mut();
    }
    let Ok(path) = (unsafe { CStr::from_ptr(path) }).to_str() else {
        return ptr::null_mut();
    };
    let key = unsafe { device.cast::<[u8; 32]>().read() };
    Session::new(path.into(), key).map_or(ptr::null_mut(), |s| Box::into_raw(Box::new(s)))
}
#[unsafe(no_mangle)]
unsafe extern "C" fn kk_call(s: *mut Session, request: *const c_char) -> *mut c_char {
    let result = (|| {
        let session = unsafe { s.as_mut() }.ok_or("Нет сеанса")?;
        if request.is_null() {
            return Err("Пустой запрос");
        }
        session.call(
            serde_json::from_slice(unsafe { CStr::from_ptr(request) }.to_bytes())
                .map_err(|_| "Некорректный запрос")?,
        )
    })();
    let response = match result {
        Ok(x) => json!({"value":x}),
        Err(e) => json!({"error":e}),
    };
    CString::new(response.to_string()).unwrap().into_raw()
}
#[unsafe(no_mangle)]
unsafe extern "C" fn kk_free_text(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) })
    }
}
#[unsafe(no_mangle)]
unsafe extern "C" fn kk_close(s: *mut Session) {
    if !s.is_null() {
        drop(unsafe { Box::from_raw(s) })
    }
}

/// Called exclusively by the native owner-authentication completion handler.
#[unsafe(no_mangle)]
unsafe extern "C" fn kk_authenticated_pin(s: *mut Session) -> *mut c_char {
    let Some(pin) = (unsafe { s.as_ref() }).and_then(Session::active_pin) else {
        return ptr::null_mut();
    };
    CString::new(pin).map_or(ptr::null_mut(), CString::into_raw)
}
