package com.max.keykeep_passwords;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.util.Base64;
import org.json.JSONObject;
import java.io.*;

/** URI grants are held in this activity. Only encrypted export bytes survive a trip to the picker. */
final class ExchangeFiles {
    static final int DATABASE=9201, KEYFILE=9202, EXPORT=9203;
    private final Activity host;
    private Uri database, keyfile;
    private byte[] encrypted;
    String feedback="";
    ExchangeFiles(Activity host){this.host=host;}
    void clear(){database=null;keyfile=null;encrypted=null;feedback="";}
    JSONObject status() throws Exception {
        return new JSONObject().put("database",name(database)).put("keyfile",name(keyfile)).put("feedback",feedback);
    }
    private String name(Uri uri){
        if(uri==null)return "";
        try(Cursor c=host.getContentResolver().query(uri,new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)){
            if(c!=null && c.moveToFirst())return c.getString(0);
        }
        return "Выбранный файл";
    }
    void pick(int code){
        Intent i=new Intent(code==EXPORT?Intent.ACTION_CREATE_DOCUMENT:Intent.ACTION_OPEN_DOCUMENT)
            .setType("application/octet-stream").addCategory(Intent.CATEGORY_OPENABLE);
        if(code==EXPORT)i.putExtra(Intent.EXTRA_TITLE,"keykeep-vault.kdbx");
        else i.setType("*/*");
        host.startActivityForResult(i,code);
    }
    private byte[] read(Uri uri,int limit)throws IOException{
        if(uri==null)throw new IOException();
        try(InputStream in=host.getContentResolver().openInputStream(uri); ByteArrayOutputStream out=new ByteArrayOutputStream()){
            if(in==null)throw new IOException();
            byte[] buffer=new byte[8192]; int n;
            while((n=in.read(buffer))!=-1){
                if(out.size()+n>limit)throw new IOException();
                out.write(buffer,0,n);
            }
            return out.toByteArray();
        }
    }
    void prepare(JSONObject args, boolean importing)throws Exception{
        args.put("op",importing?"importKdbx":"exportKdbx");
        if(keyfile!=null)args.put("keyfile",Base64.encodeToString(read(keyfile,4<<20),Base64.NO_WRAP));
        if(importing)args.put("data",Base64.encodeToString(read(database,64<<20),Base64.NO_WRAP));
    }
    void export(String data){encrypted=Base64.decode(data,Base64.NO_WRAP);pick(EXPORT);}
    void result(int code,Uri uri) {
        if(code==EXPORT){
            try{
                if(uri==null){feedback="Сохранение отменено";return;}
                if(encrypted==null)throw new IOException();
                try(OutputStream out=host.getContentResolver().openOutputStream(uri,"rwt")){
                    if(out==null)throw new IOException();
                    out.write(encrypted);
                }
                feedback="Файл KDBX сохранён";
            }catch(Exception e){feedback="Ошибка записи файла KDBX";}
            finally{encrypted=null;keyfile=null;}
        }else if(uri!=null){
            if(code==DATABASE)database=uri;
            if(code==KEYFILE)keyfile=uri;
        }
    }
}
