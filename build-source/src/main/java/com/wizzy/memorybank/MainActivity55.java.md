` block without any wrapper formatting or modifications.
</thinking>

<script>
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
public class MainActivity extends android.app.Activity {
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
    private void createProjectDialog() {
        EditText e = new EditText(this); e.setHint("Project title"); e.setSingleLine(true);
        new AlertDialog.Builder(this).setTitle("New Memory Bank").setView(e)
                .setPositiveButton("Create", (d,w) -> {
                    String title = e.getText().toString().trim(); if (title.isEmpty()) title = "Untitled Project";
                    try { projects.put(new JSONObject().put("title", title).put("memory", "").put("chat", "").put("sources", new JSONArray())); saveProjects(); selectedProject = projects.length()-1; setupProjectSpinner(); refreshAll(); }
                    catch (Exception ex) { toast("Could not create project"); }
                }).setNegativeButton("Cancel", null).show();
    }
    private void send() {
        String message = messageInput.getText().toString().trim();
        if (message.isEmpty()) return;
        if (!openAiCheck.isChecked() && !geminiCheck.isChecked()) { toast("Select OpenAI, Gemini, or both."); return; }
        append("Kevin", message); messageInput.setText("");
        if (saveMemoryCheck.isChecked()) appendMemory("Kevin: " + message);
        setBusy(true);
        final String prompt = buildPrompt(message);
        final int[] pending = { (openAiCheck.isChecked()?1:0) + (geminiCheck.isChecked()?1:0) };
        Runnable done = () -> { synchronized (pending) { pending[0]--; if (pending[0] == 0) runOnUiThread(() -> setBusy(false)); } };
        if (openAiCheck.isChecked()) executor.execute(() -> { callOpenAI(prompt); done.run(); });
        if (geminiCheck.isChecked()) executor.execute(() -> { callGemini(prompt); done.run(); });
    }
    private String buildPrompt(String latest) {
        String memory = getProjectString("memory");
        String recent = getProjectString("chat");
        if (recent.length() > 7000) recent = recent.substring(recent.length() - 7000);
        String retrieved = retrieveRelevantChunks(latest, 6);
        return "You are participating in Brain Fuze, a shared project room with Kevin and another AI collaborator. " +
                "The active project is '" + project().optString("title", "Untitled") + "'. Use the supplied shared memory and source excerpts. " +
                "Identify yourself clearly, do not impersonate the other provider, preserve locked decisions, and say when the provided memory does not support a claim.\n\n" +
                "PROJECT MEMORY:\n" + (memory.isEmpty()?"No manually saved memory yet.":memory) +
                "\n\nRELEVANT IMPORTED SOURCE EXCERPTS:\n" + (retrieved.isEmpty()?"No matching imported excerpts.":retrieved) +
                "\n\nRECENT GROUP CHAT:\n" + recent + "\n\nKEVIN'S NEW MESSAGE:\n" + latest;
    }
    private String retrieveRelevantChunks(String query, int limit) {
        JSONArray sources = project().optJSONArray("sources"); if (sources == null) return "";
        Set<String> words = keywords(query); List<ScoredChunk> scored = new ArrayList<>();
        for (int i=0;i<sources.length();i++) {
            JSONObject source = sources.optJSONObject(i); if (source == null) continue;
            JSONArray chunks = source.optJSONArray("chunks"); if (chunks == null) continue;
            for (int j=0;j<chunks.length();j++) {
                String text = chunks.optString(j, ""); int score = 0; String low = text.toLowerCase(Locale.US);
                for (String w: words) if (low.contains(w)) score++;
                if (score > 0 || words.isEmpty()) scored.add(new ScoredChunk(score, source.optString("name", "PDF"), j+1, text));
            }
        }
        Collections.sort(scored, (a,b) -> Integer.compare(b.score, a.score));
        StringBuilder out = new StringBuilder();
        for (int i=0;i<Math.min(limit, scored.size());i++) {
            ScoredChunk c=scored.get(i); out.append("[Source: ").append(c.source).append(" • Segment ").append(c.index).append("]\n").append(c.text).append("\n\n");
        }
        return out.toString();
    }
    private Set<String> keywords(String s) {
        Set<String> stop = new HashSet<>(Arrays.asList("the","and","that","this","with","from","have","what","when","where","would","could","should","about","into","your","you","for","are","was","were","but","not","our","its","they","them","then"));
        Set<String> out = new HashSet<>(); for (String w: s.toLowerCase(Locale.US).split("[^a-z0-9]+")) if (w.length()>3 && !stop.contains(w)) out.add(w); return out;
    }
    private static class ScoredChunk { int score,index; String source,text; ScoredChunk(int s,String n,int i,String t){score=s;source=n;index=i;text=t;} }
    private void choosePdf() {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT); i.addCategory(Intent.CATEGORY_OPENABLE); i.setType("application/pdf"); startActivityForResult(i, PICK_PDF);
    }
    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == PICK_PDF && resultCode == RESULT_OK && data != null && data.getData() != null) {
            Uri uri = data.getData(); try { getContentResolver().takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION); } catch (Exception ignored) {}
            importPdf(uri);
        }
    }
    private void importPdf(Uri uri) {
        setBusy(true); final String name = displayName(uri);
        executor.execute(() -> {
            try (InputStream in = getContentResolver().openInputStream(uri); PDDocument doc = PDDocument.load(in)) {
                String text = new PDFTextStripper().getText(doc).replace("\u0000", "").trim();
                if (text.length() < 40) throw new IOException("No readable text found. This PDF may be scanned images and need OCR.");
                JSONArray chunks = splitChunks(text); JSONObject source = new JSONObject().put("name", name).put("imported", System.currentTimeMillis()).put("chunks", chunks);
                runOnUiThread(() -> {
                    try { JSONArray sources = project().optJSONArray("sources"); if (sources == null) { sources = new JSONArray(); project().put("sources", sources); } sources.put(source); saveProjects(); refreshStats(); toast("Imported " + name + " as " + chunks.length() + " hidden memory segments"); }
                    catch (Exception e) { toast("Could not save imported PDF"); }
                    setBusy(false);
                });
            } catch (Exception e) { runOnUiThread(() -> { setBusy(false); toast("PDF import failed: " + cleanError(e)); }); }
        });
    }
    private JSONArray splitChunks(String text) {
        JSONArray arr = new JSONArray(); int start=0;
        while (start < text.length()) { int end=Math.min(text.length(), start+CHUNK_SIZE); if (end<text.length()) { int p=text.lastIndexOf('\n',end); if (p>start+900) end=p; } arr.put(text.substring(start,end).trim()); if (end>=text.length()) break; start=Math.max(start+1,end-CHUNK_OVERLAP); }
        return arr;
    }
    private String displayName(Uri uri) {
        String name="Imported PDF"; try (android.database.Cursor c=getContentResolver().query(uri,null,null,null,null)) { if (c!=null && c.moveToFirst()) { int ix=c.getColumnIndex(OpenableColumns.DISPLAY_NAME); if(ix>=0) name=c.getString(ix); } } catch(Exception ignored){} return name;
    }
    private void callOpenAI(String prompt) {
        String key = secureStore.get("openai_key").trim();
        final String model = "gpt-5-mini";
        if (key.isEmpty()) { result("OpenAI", "API key is not configured. Open API Settings."); return; }
        try {
            JSONObject body = new JSONObject().put("model", model).put("input", prompt);
            JSONObject json = post("https://api.openai.com/v1/responses", body, "Authorization", "Bearer " + key);
            String text = json.optString("output_text", ""); JSONArray output = json.optJSONArray("output");
            if (text.isEmpty() && output != null) for (int i=0;i<output.length();i++) { JSONArray content=output.getJSONObject(i).optJSONArray("content"); if(content!=null) for(int j=0;j<content.length();j++){ String t=content.getJSONObject(j).optString("text",""); if(!t.isEmpty()) text+=t; }}
            result("OpenAI", text.isEmpty()?"No text response returned.":text);
        } catch (Exception e) { result("OpenAI error", cleanError(e)); }
    }
    private void callGemini(String prompt) {
        String key = secureStore.get("gemini_key").trim();
        final String model = "gemini-3-flash-preview";
        if (key.isEmpty()) { result("Gemini", "API key is not configured. Open API Settings."); return; }
        try {
            JSONObject body = new JSONObject().put("contents", new JSONArray().put(new JSONObject().put("role", "user").put("parts", new JSONArray().put(new JSONObject().put("text", prompt)))));
            JSONObject json = post("https://generativelanguage.googleapis.com/v1beta/models/" + model + ":generateContent", body, "x-goog-api-key", key);
            String text = json.getJSONArray("candidates").getJSONObject(0).getJSONObject("content").getJSONArray("parts").getJSONObject(0).optString("text", "No text response returned."); result("Gemini", text);
        } catch (Exception e) { result("Gemini error", cleanError(e)); }
    }
    private JSONObject post(String endpoint, JSONObject body, String header, String value) throws Exception {
        HttpURLConnection c=(HttpURLConnection)new URL(endpoint).openConnection(); c.setRequestMethod("POST"); c.setConnectTimeout(30000); c.setReadTimeout(90000); c.setDoOutput(true); c.setRequestProperty("Content-Type","application/json"); c.setRequestProperty(header,value);
        try(OutputStream os=c.getOutputStream()){os.write(body.toString().getBytes(StandardCharsets.UTF_8));}
        int status=c.getResponseCode(); InputStream stream=status>=200&&status<300?c.getInputStream():c.getErrorStream(); String response=readAll(stream); if(status<200||status>=300) throw new IOException("HTTP "+status+": "+response); return new JSONObject(response);
    }
    private String readAll(InputStream stream) throws IOException { if(stream==null)return""; BufferedReader r=new BufferedReader(new InputStreamReader(stream,StandardCharsets.UTF_8)); StringBuilder b=new StringBuilder(); String line; while((line=r.readLine())!=null)b.append(line); return b.toString(); }
    private void result(String who,String text){runOnUiThread(()->{append(who,text); if(saveMemoryCheck.isChecked())appendMemory(who+": "+text);});}
    private void append(String who,String text){String stamp=new SimpleDateFormat("MMM d, h:mm a",Locale.US).format(new Date()); String current=getProjectString("chat"); current+=(current.isEmpty()?"":"\n\n")+"["+stamp+"] "+who+"\n"+text; putProjectString("chat",current); refreshChat();}
    private void appendMemory(String line){String memory=getProjectString("memory"); memory+=(memory.isEmpty()?"":"\n")+line; if(memory.length()>120000)memory=memory.substring(memory.length()-120000); putProjectString("memory",memory); refreshStats();}
    private void refreshAll(){refreshChat();refreshStats();}
    private void refreshChat(){String chat=getProjectString("chat"); chatDisplay.setText(chat.isEmpty()?"Brain Fuze is ready. Add project memory or import a PDF, choose OpenAI, Gemini, or both, then start the room.":chat); chatDisplay.post(()->((ScrollView)findViewById(R.id.chatScroll)).fullScroll(View.FOCUS_DOWN));}
    private void refreshStats(){JSONArray sources=project().optJSONArray("sources"); int sourceCount=sources==null?0:sources.length(); int segments=0; if(sources!=null)for(int i=0;i<sources.length();i++){JSONArray c=sources.optJSONObject(i).optJSONArray("chunks");if(c!=null)segments+=c.length();} projectStats.setText("Shared memory • "+sourceCount+" PDFs • "+segments+" hidden segments");}
    private void showSettings() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int p = 24;
        box.setPadding(p, p, p, p);
        EditText oa = field("OpenAI API key", secureStore.get("openai_key"), true);
        EditText ga = field("Gemini API key", secureStore.get("gemini_key"), true);
        box.addView(oa); box.addView(ga);
        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("API Settings")
                .setView(box)
                .setMessage("Paste one key for each provider. Brain Fuze uses GPT-5 mini and Gemini 3 Flash automatically.")
                .setPositiveButton("Save", null)
                .setNegativeButton("Cancel", null)
                .create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            try {
                String openKey = oa.getText().toString().trim();
                String geminiKey = ga.getText().toString().trim();
                secureStore.put("openai_key", openKey);
                secureStore.put("gemini_key", geminiKey);
                prefs.edit().remove("openai_model").remove("gemini_model").commit();
                boolean openOk = openKey.isEmpty() || secureStore.has("openai_key");
                boolean geminiOk = geminiKey.isEmpty() || secureStore.has("gemini_key");
                if (!openOk || !geminiOk) {
                    toast("Key save verification failed. Please try once more.");
                    return;
                }
                toast("API settings saved: OpenAI " + (openKey.isEmpty()?"empty":"ready") + ", Gemini " + (geminiKey.isEmpty()?"empty":"ready"));
                dialog.dismiss();
            } catch (Exception e) {
                toast("Could not save API keys: " + e.getMessage());
            }
        }));
        dialog.show();
    }
    private EditText field(String hint,String value,boolean secret){EditText e=new EditText(this);e.setHint(hint);e.setText(value);e.setSingleLine(true);if(secret)e.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);return e;}
    private void showMemory(){EditText e=new EditText(this);e.setMinLines(12);e.setGravity(Gravity.TOP);e.setText(getProjectString("memory"));e.setHint("Locked decisions, current goals, summaries, and context for this project.");new AlertDialog.Builder(this).setTitle(project().optString("title","Project")+" Memory").setView(e).setPositiveButton("Save",(d,w)->{putProjectString("memory",e.getText().toString());refreshStats();toast("Project memory saved");}).setNeutralButton("Copy",(d,w)->copy(e.getText().toString(),"Memory copied")).setNegativeButton("Cancel",null).show();}
    private void showAbout(){new AlertDialog.Builder(this).setTitle("Brain Fuze").setMessage("Shared Intelligence. Shared Memory.\n\nCreated and led by Kevin.\nAI development collaboration: OpenAI ChatGPT.\nGoogle Gemini is supported as an independent AI participant.\n\nLet's Fuze Some Brains.").setPositiveButton("Close",null).show();}
    private void confirmClear(){new AlertDialog.Builder(this).setTitle("Clear this project chat?").setMessage("Project memory and imported PDFs will be kept.").setPositiveButton("Clear",(d,w)->{putProjectString("chat","");refreshChat();}).setNegativeButton("Cancel",null).show();}
    private void copy(String text,String msg){((ClipboardManager)getSystemService(Context.CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("Brain Fuze",text));toast(msg);}
    private void setBusy(boolean busy){loadingBar.setVisibility(busy?View.VISIBLE:View.GONE);findViewById(R.id.sendButton).setEnabled(!busy);findViewById(R.id.importPdfButton).setEnabled(!busy);}
    private String cleanError(Exception e){
        String s=e.getMessage();
        if(s==null)s=e.getClass().getSimpleName();
        s=s.replaceAll("sk-[A-Za-z0-9_-]{12,}", "[OPENAI_KEY_REDACTED]");
        s=s.replaceAll("AIza[A-Za-z0-9_-]{20,}", "[GEMINI_KEY_REDACTED]");
        return s.length()>1200?s.substring(0,1200):s;
    }
    private void toast(String s){Toast.makeText(this,s,Toast.LENGTH_LONG).show();}
}