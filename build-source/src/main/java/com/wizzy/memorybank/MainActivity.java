package com.wizzy.memorybank;

import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.text.InputType;
import android.view.Gravity;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.View;
import android.widget.*;

// Added Core AndroidX Imports
import androidx.appcompat.app.AppCompatActivity;
import com.wizzy.memorybank.R;

import com.tom_roush.pdfbox.android.PDFBoxResourceLoader;
import com.tom_roush.pdfbox.pdmodel.PDDocument;
import com.tom_roush.pdfbox.text.PDFTextStripper;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

// Changed from android.app.Activity to AppCompatActivity
public class MainActivity extends AppCompatActivity {
    private static final int PICK_PDF = 4101;
    private static final String PREFS = "brain_fuze";
    private static final String PROJECTS_KEY = "projects_json";
    private static final int CHUNK_SIZE = 2200;
    private static final int CHUNK_OVERLAP = 250;
    private TextView chatDisplay, projectStats;
    private EditText messageInput;
    private CheckBox openAiCheck, geminiCheck, saveMemoryCheck;
    private ProgressBar loadingBar;
    private Spinner projectSpinner;
    private FrameLayout introOverlay;
    private VideoView introVideo;
    private boolean introFinished = false;
    private final ExecutorService executor = Executors.newFixedThreadPool(3);
    private android.content.SharedPreferences prefs;
    private SecureStore secureStore;
    private JSONArray projects;
    private int selectedProject = 0;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(R.layout.activity_main);
        enableImmersiveMode();
        PDFBoxResourceLoader.init(getApplicationContext());
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        secureStore = new SecureStore(this);
        bindViews();
        loadProjects();
        setupProjectSpinner();
        setupActions();
        refreshAll();
        playIntro();
    }

    private void enableImmersiveMode() {
        Window window = getWindow();
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false);
            WindowInsetsController controller = window.getInsetsController();
            if (controller != null) {
                controller.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
                controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            window.getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY |
                    View.SYSTEM_UI_FLAG_FULLSCREEN |
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN |
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION |
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
        }
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) enableImmersiveMode();
    }

    private void bindViews() {
        chatDisplay = findViewById(R.id.chatDisplay);
        projectStats = findViewById(R.id.projectStats);
        messageInput = findViewById(R.id.messageInput);
        openAiCheck = findViewById(R.id.openAiCheck);
        geminiCheck = findViewById(R.id.geminiCheck);
        saveMemoryCheck = findViewById(R.id.saveMemoryCheck);
        loadingBar = findViewById(R.id.loadingBar);
        projectSpinner = findViewById(R.id.projectSpinner);
        introOverlay = findViewById(R.id.introOverlay);
        introVideo = findViewById(R.id.introVideo);
    }

    private void setupActions() {
        findViewById(R.id.sendButton).setOnClickListener(v -> send());
        findViewById(R.id.settingsButton).setOnClickListener(v -> showSettings());
        findViewById(R.id.memoryButton).setOnClickListener(v -> showMemory());
        findViewById(R.id.importPdfButton).setOnClickListener(v -> choosePdf());
        findViewById(R.id.newProjectButton).setOnClickListener(v -> createProjectDialog());
        findViewById(R.id.exportButton).setOnClickListener(v -> copy(getProjectString("chat"), "Chat copied"));
        findViewById(R.id.clearButton).setOnClickListener(v -> confirmClear());
        findViewById(R.id.aboutButton).setOnClickListener(v -> showAbout());
    }

    private void playIntro() {
        if (introOverlay == null || introVideo == null) return;
        introFinished = false;
        introOverlay.setVisibility(View.VISIBLE);
        introOverlay.setAlpha(1f);
        Uri uri = Uri.parse("android.resource://" + getPackageName() + "/" + R.raw.brain_fuze_intro);
        introVideo.setVideoURI(uri);
        introVideo.setOnPreparedListener(mp -> {
            mp.setLooping(false);
            mp.setVideoScalingMode(MediaPlayer.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING);
            introVideo.start();
        });
        introVideo.setOnCompletionListener(mp -> endIntro());
        introVideo.setOnErrorListener((mp, what, extra) -> {
            endIntro();
            return true;
        });
        introOverlay.setOnClickListener(v -> endIntro());
    }

    private void endIntro() {
        if (introFinished) return;
        introFinished = true;
        try { introVideo.stopPlayback(); } catch (Exception ignored) {}
        introOverlay.animate().alpha(0f).setDuration(400)
                .withEndAction(() -> {
                    introOverlay.setVisibility(View.GONE);
                    introOverlay.setAlpha(1f);
                }).start();
    }

    private void loadProjects() {
        try { projects = new JSONArray(prefs.getString(PROJECTS_KEY, "[]")); }
        catch (Exception e) { projects = new JSONArray(); }
        if (projects.length() == 0) {
            JSONObject p = new JSONObject();
            try {
                p.put("title", "Genesis"); p.put("memory", ""); p.put("chat", ""); p.put("sources", new JSONArray());
                projects.put(p); saveProjects();
            } catch (Exception ignored) { }
        }
    }

    private void saveProjects() { prefs.edit().putString(PROJECTS_KEY, projects.toString()).apply(); }

    private JSONObject project() {
        try { return projects.getJSONObject(Math.max(0, Math.min(selectedProject, projects.length()-1))); }
        catch (Exception e) { return new JSONObject(); }
    }

    private String getProjectString(String key) { return project().optString(key, ""); }

    private void putProjectString(String key, String value) { try { project().put(key, value); saveProjects(); } catch (Exception ignored) {} }

    private void setupProjectSpinner() {
        List<String> names = new ArrayList<>();
        for (int i=0;i<projects.length();i++) names.add(projects.optJSONObject(i).optString("title", "Project " + (i+1)));
        ArrayAdapter<String> adapter = new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, names);
        projectSpinner.setAdapter(adapter);
        projectSpinner.setSelection(Math.min(selectedProject, names.size()-1));
        projectSpinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override public void onItemSelected(AdapterView<?> parent, View view, int position, long id) { selectedProject = position; refreshAll(); }
            @Override public void onNothingSelected(AdapterView<?> parent) { }
        });
    }

    // Stubs for remaining helper methods referenced in code layout requirements
    private void send() {}
    private void showSettings() {}
    private void showMemory() {}
    private void choosePdf() {}
    private void createProjectDialog() {}
    private void confirmClear() {}
    private void showAbout() {}
    private void refreshAll() {}
    private void copy(String content, String message) {}
}
