package com.example.quickchatwidget;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.speech.RecognizerIntent;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;

public class ComposerActivity extends Activity {
    private static final int SPEECH_REQUEST = 100;
    private EditText input;
    private TextView hint;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_composer);

        input = findViewById(R.id.input_text);
        hint = findViewById(R.id.target_hint);
        Button mic = findViewById(R.id.btn_mic);
        Button open = findViewById(R.id.btn_open_chat);
        Button settings = findViewById(R.id.btn_settings);

        input.requestFocus();
        refreshTargetHint();

        mic.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                startVoiceInput();
            }
        });

        open.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                copyAndOpenChat();
            }
        });

        settings.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                startActivity(new Intent(ComposerActivity.this, SettingsActivity.class));
            }
        });
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (hint != null) {
            refreshTargetHint();
        }
    }

    private void startVoiceInput() {
        Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, "ru-RU");
        intent.putExtra(RecognizerIntent.EXTRA_PROMPT, "Скажи, что нужно записать");
        try {
            startActivityForResult(intent, SPEECH_REQUEST);
        } catch (Exception e) {
            Toast.makeText(this, "Голосовой ввод недоступен на этом устройстве", Toast.LENGTH_LONG).show();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == SPEECH_REQUEST && resultCode == RESULT_OK && data != null) {
            ArrayList<String> matches = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS);
            if (matches != null && !matches.isEmpty()) {
                String spoken = matches.get(0);
                if (input.getText().length() > 0) {
                    input.append(" ");
                }
                input.append(spoken);
            }
        }
    }

    private void copyAndOpenChat() {
        String text = input.getText().toString().trim();
        if (text.isEmpty()) {
            input.setError("Напиши или продиктуй задачу");
            return;
        }

        ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboard != null) {
            clipboard.setPrimaryClip(ClipData.newPlainText("Задача для ChatGPT", text));
        }

        SharedPreferences prefs = getSharedPreferences("settings", MODE_PRIVATE);
        String url = prefs.getString("chat_url", "").trim();

        Intent intent;
        if (!url.isEmpty()) {
            intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
        } else {
            intent = getPackageManager().getLaunchIntentForPackage("com.openai.chatgpt");
            if (intent == null) {
                intent = new Intent(Intent.ACTION_VIEW, Uri.parse("https://chatgpt.com/"));
            }
        }

        Toast.makeText(this, "Скопировано. Вставь текст в открывшийся чат.", Toast.LENGTH_LONG).show();
        startActivity(intent);
    }

    private void refreshTargetHint() {
        SharedPreferences prefs = getSharedPreferences("settings", MODE_PRIVATE);
        String url = prefs.getString("chat_url", "").trim();
        hint.setText(url.isEmpty()
                ? "Откроется приложение ChatGPT"
                : "Откроется выбранный чат ChatGPT");
    }
}
