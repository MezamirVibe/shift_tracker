package com.example.quickchatwidget;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.Toast;

public class SettingsActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_settings);

        EditText urlInput = findViewById(R.id.chat_url);
        Button save = findViewById(R.id.btn_save);
        Button clear = findViewById(R.id.btn_clear);

        SharedPreferences prefs = getSharedPreferences("settings", MODE_PRIVATE);
        urlInput.setText(prefs.getString("chat_url", ""));

        save.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                String value = urlInput.getText().toString().trim();
                if (!value.isEmpty()
                        && !(value.startsWith("https://chatgpt.com/c/")
                        || value.startsWith("https://chat.openai.com/c/"))) {
                    urlInput.setError("Нужна ссылка вида https://chatgpt.com/c/...");
                    return;
                }
                prefs.edit().putString("chat_url", value).apply();
                Toast.makeText(SettingsActivity.this, "Сохранено", Toast.LENGTH_SHORT).show();
                finish();
            }
        });

        clear.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                prefs.edit().remove("chat_url").apply();
                urlInput.setText("");
                Toast.makeText(SettingsActivity.this, "Будет открываться просто ChatGPT", Toast.LENGTH_SHORT).show();
            }
        });
    }
}
