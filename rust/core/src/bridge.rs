//! The native UI owns exactly one session and serializes all calls on its main thread.
use crate::session::Session;
use serde_json::json;
use std::{
    ffi::{CStr, CString, c_char},
    ptr,
};

// Native catalog verified the file identity and retains the original profile lock.
#[unsafe(no_mangle)]
unsafe extern "C" fn kk_relocate(s: *mut Session, path: *const c_char) {
    if let Some(s) = unsafe { s.as_mut() }
        && !path.is_null()
        && let Ok(path) = unsafe { CStr::from_ptr(path) }.to_str()
    {
        s.path = path.into();
    }
}
#[unsafe(no_mangle)]
unsafe extern "C" fn kk_new(path: *const c_char) -> *mut Session {
    if path.is_null() {
        return ptr::null_mut();
    }
    let Ok(path) = (unsafe { CStr::from_ptr(path) }).to_str() else {
        return ptr::null_mut();
    };
    Session::new(path.into(), [0; 32]).map_or(ptr::null_mut(), |s| Box::into_raw(Box::new(s)))
}
#[unsafe(no_mangle)]
unsafe extern "C" fn kk_new_at(path: *const c_char, state: *const c_char) -> *mut Session {
    if path.is_null() || state.is_null() {
        return ptr::null_mut();
    }
    let (Ok(path), Ok(state)) = (
        (unsafe { CStr::from_ptr(path) }).to_str(),
        (unsafe { CStr::from_ptr(state) }).to_str(),
    ) else {
        return ptr::null_mut();
    };
    Session::with_state(path.into(), state.into(), [0; 32])
        .map_or(ptr::null_mut(), |s| Box::into_raw(Box::new(s)))
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

#[unsafe(no_mangle)]
unsafe extern "C" fn kk_finish_erasure(session: *mut Session, key: *const u8) -> bool {
    let Some(session) = (unsafe { session.as_mut() }) else {
        return false;
    };
    if key.is_null() {
        return false;
    }
    session
        .finish_erasure(unsafe { key.cast::<[u8; 32]>().read() })
        .is_ok()
}

#[unsafe(no_mangle)]
unsafe extern "C" fn kk_erasing(s: *mut Session) -> bool {
    unsafe { s.as_ref() }.is_some_and(Session::erasing)
}
#[unsafe(no_mangle)]
unsafe extern "C" fn kk_initialize_device(s: *mut Session, key: *const u8) -> bool {
    let Some(s) = (unsafe { s.as_mut() }) else {
        return false;
    };
    if key.is_null() {
        return false;
    }
    s.initialize_device(unsafe { key.cast::<[u8; 32]>().read() })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn kk_shared_oauth(request: *const c_char) -> *mut c_char {
    let result = (|| {
        if request.is_null() {
            return Err("Пустой запрос");
        }
        let query = serde_json::from_slice(unsafe { CStr::from_ptr(request) }.to_bytes())
            .map_err(|_| "Некорректный запрос")?;
        crate::yandex::shared_oauth(query)
    })();
    let response = match result {
        Ok(value) => json!({"value":value}),
        Err(error) => json!({"error":error}),
    };
    CString::new(response.to_string()).unwrap().into_raw()
}

// The native owner obtains a reference while on its serialized session thread.
// A background wait consumes only the signal reference, never the vault handle.
#[unsafe(no_mangle)]
unsafe extern "C" fn kk_mcp_signal(s: *mut Session) -> *const crate::mcp::Signal {
    unsafe { s.as_ref() }
        .and_then(|s| s.mcp.as_ref())
        .map_or(ptr::null(), |m| {
            std::sync::Arc::into_raw(m.transport.signal.clone())
        })
}
#[unsafe(no_mangle)]
unsafe extern "C" fn kk_wait_signal(signal: *const crate::mcp::Signal) {
    if !signal.is_null() {
        unsafe { std::sync::Arc::from_raw(signal) }.wait();
    }
}
