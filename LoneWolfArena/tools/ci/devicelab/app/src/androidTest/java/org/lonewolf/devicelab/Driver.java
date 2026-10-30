package org.lonewolf.devicelab;

import android.app.Instrumentation;
import android.app.UiAutomation;
import android.graphics.Bitmap;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.UiDevice;

import com.google.android.gms.tasks.Tasks;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.Text;
import com.google.mlkit.vision.text.TextRecognition;
import com.google.mlkit.vision.text.TextRecognizer;
import com.google.mlkit.vision.text.latin.TextRecognizerOptions;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Drives a reference app on a real phone the way a tester would, by reading its screen: installs
 * its split APKs (pushed to `apks` by the test run), launches it, then every loop takes a
 * screenshot (kept for the results), reads its words (ML Kit, on the phone) and taps the first word
 * of PLAN that is on screen; words of AVOID are never tapped (sign-ins, money, other players). Once
 * a practice mode was entered it plays with the usual places of a shooter's touch layout. Same
 * rules as tools/ci/reference_nav.py (the emulator version). Arguments: pkg, apks, minutes.
 */
@RunWith(AndroidJUnit4.class)
public class Driver {
    private static final String TAG = "DeviceLab";
    private static final String[] PLAN = {"guest", "agree", "accept", "confirm", "ok", "okay", "yes", "continue",
            "next", "skip", "got it", "tap to start", "tap to begin", "touch to start", "download", "update", "later",
            "not now", "close", "claim", "collect", "training"};
    private static final String[] AVOID = {"facebook", "google", "vk", "twitter", "apple", "huawei", "line",
            "purchase", "buy", "top up", "topup", "recharge", "diamond", "pay", "ranked", "rank", "redeem", "delete",
            "logout", "log out", "exit", "quit", "bind", "invite", "friend", "squad", "duo", "team", "share",
            "report", "store", "shop"};

    private UiAutomation ua;
    private UiDevice dev;
    private File out;
    private FileWriter log;
    private long t0;
    private int width;
    private int height;

    /** A line of text on the screen, in display coordinates. */
    private static final class Phrase {
        final String text;
        final Rect box;

        Phrase(String text, Rect box) {
            this.text = text;
            this.box = box;
        }
    }

    @Test
    public void drive() throws Exception {
        Instrumentation inst = InstrumentationRegistry.getInstrumentation();
        ua = inst.getUiAutomation();
        dev = UiDevice.getInstance(inst);
        Bundle args = InstrumentationRegistry.getArguments();
        String pkg = args.getString("pkg", "com.dts.freefireth");
        String apks = args.getString("apks", "/data/local/tmp/ffdrv");
        double minutes = Double.parseDouble(args.getString("minutes", "20"));
        out = new File(inst.getTargetContext().getExternalFilesDir(null), "run");
        new File(out, "frames").mkdirs();
        log = new FileWriter(new File(out, "nav.txt"), true);
        t0 = System.currentTimeMillis();
        sh("svc power stayon true");
        sh("settings put system screen_off_timeout 2147483647");
        log("device " + android.os.Build.MANUFACTURER + " " + android.os.Build.MODEL + " sdk " + android.os.Build.VERSION.SDK_INT
                + " abis " + String.join(",", android.os.Build.SUPPORTED_ABIS));
        install(pkg, apks);
        sh("monkey -p " + pkg + " -c android.intent.category.LAUNCHER 1");
        log("launched");
        TextRecognizer ocr = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS);
        Map<String, Integer> tapped = new HashMap<>();
        boolean playing = false;
        boolean named = false;
        long since = System.currentTimeMillis();
        int frame = 0;
        int step = 0;
        Random rng = new Random();
        while (System.currentTimeMillis() - t0 < minutes * 60_000) {
            width = dev.getDisplayWidth();
            height = dev.getDisplayHeight();
            Bitmap bmp = ua.takeScreenshot();
            if (bmp == null) {
                Thread.sleep(2000);
                continue;
            }
            saveFrame(bmp, frame++);
            if (black(bmp)) {
                log("black screen");
                since = System.currentTimeMillis();
                Thread.sleep(3000);
                continue;
            }
            List<Phrase> phrases = read(ocr, bmp);
            StringBuilder seen = new StringBuilder();
            for (int i = 0; i < Math.min(14, phrases.size()); i++) {
                seen.append(i == 0 ? "" : " | ").append(phrases.get(i).text);
            }
            log("seen: " + seen);
            String all = seen.toString().toLowerCase(Locale.ROOT);
            if (frame % 10 == 0 && sh("pidof " + pkg).trim().isEmpty()) {
                sh("monkey -p " + pkg + " -c android.intent.category.LAUNCHER 1");
                log("the app was not running: launched it again");
                Thread.sleep(20000);
                continue;
            }
            if (playing) {
                Phrase dialog = decide(phrases, tapped, false);
                if (dialog != null && word(dialog.text, "ok", "confirm", "close", "skip", "continue", "got it")) {
                    tap(dialog, "dialog during practice");
                } else {
                    play(step++);
                }
                continue;
            }
            if (has(all, "exit") || has(all, "quit")) {
                Phrase no = find(phrases, "cancel", "no");
                if (no != null) {
                    tap(no, "exit question");
                    Thread.sleep(2000);
                    continue;
                }
            }
            if (!named && (all.contains("nickname") || all.contains("enter name") || all.contains("your name"))) {
                Phrase box = find(phrases, "enter");
                if (box != null) {
                    dev.click(box.box.centerX(), box.box.centerY());
                } else {
                    dev.click(width / 2, height / 2);
                }
                Thread.sleep(1500);
                sh(String.format(Locale.ROOT, "input text Wolf%04d", rng.nextInt(10000)));
                sh("input keyevent 66");
                named = true;
                log("typed a name");
                continue;
            }
            Phrase choice = decide(phrases, tapped, true);
            if (choice != null) {
                String key = choiceWord(choice.text) + "@" + choice.box.centerX() / 40 + "," + choice.box.centerY() / 40;
                tapped.put(key, tapped.getOrDefault(key, 0) + 1);
                tap(choice, "plan word " + choiceWord(choice.text));
                since = System.currentTimeMillis();
                if (word(choice.text, "start") && has(all, "training")) {
                    playing = true;
                    log("practice started: playing from now on");
                    Thread.sleep(60000);
                } else {
                    Thread.sleep(2500);
                }
                continue;
            }
            if (System.currentTimeMillis() - since > 240_000) {
                dev.pressBack();
                log("nothing to tap for 240 s: back");
                since = System.currentTimeMillis();
            }
            Thread.sleep(2000);
        }
        log("done: " + frame + " screenshots");
        log.close();
    }

    /** Installs every .apk in dir as one app (base + splits), like `adb install-multiple`: by path
     *  first, then (if the system may not read the files there) streamed through the shell. */
    private void install(String pkg, String dir) throws Exception {
        for (boolean piped : new boolean[] {false, true}) {
            String created = sh("pm install-create -r -g");
            Matcher m = Pattern.compile("\\[(\\d+)]").matcher(created);
            if (!m.find()) {
                log("install-create failed: " + created.trim());
                return;
            }
            String session = m.group(1);
            int n = 0;
            for (String name : sh("ls " + dir).split("\\s+")) {
                if (!name.endsWith(".apk")) {
                    continue;
                }
                String path = dir + "/" + name;
                String size = sh("stat -c %s " + path).trim();
                String w = piped ? writePiped(session, name, path, size)
                        : sh("pm install-write -S " + size + " " + session + " " + name + " " + path);
                log((piped ? "stream " : "write ") + name + " (" + size + " bytes): " + w.trim());
                n++;
            }
            String done = sh("pm install-commit " + session).trim();
            log("install-commit (" + n + " apks" + (piped ? ", streamed" : "") + "): " + done);
            if (done.contains("Success")) {
                break;
            }
        }
        log("installed: " + sh("pm path " + pkg).replace('\n', ' ').trim());
    }

    /** `pm install-write ... -` with the file's bytes copied from `cat` (both run as the shell). */
    private String writePiped(String session, String name, String path, String size) {
        StringBuilder sb = new StringBuilder();
        try {
            ParcelFileDescriptor[] rw = ua.executeShellCommandRw("pm install-write -S " + size + " " + session + " " + name + " -");
            try (ParcelFileDescriptor src = ua.executeShellCommand("cat " + path);
                 InputStream in = new FileInputStream(src.getFileDescriptor());
                 OutputStream to = new FileOutputStream(rw[1].getFileDescriptor())) {
                byte[] buf = new byte[1 << 16];
                int n;
                while ((n = in.read(buf)) > 0) {
                    to.write(buf, 0, n);
                }
            }
            rw[1].close();
            try (InputStream res = new FileInputStream(rw[0].getFileDescriptor())) {
                byte[] buf = new byte[4096];
                int n;
                while ((n = res.read(buf)) > 0) {
                    sb.append(new String(buf, 0, n));
                }
            }
            rw[0].close();
        } catch (Exception e) {
            sb.append("error: ").append(e);
        }
        return sb.toString();
    }

    /** The phrase to tap now: the first PLAN word on screen ("start" only beside "training"). */
    private Phrase decide(List<Phrase> phrases, Map<String, Integer> tapped, boolean allowStart) {
        StringBuilder all = new StringBuilder();
        for (Phrase p : phrases) {
            all.append(p.text.toLowerCase(Locale.ROOT)).append(" | ");
        }
        boolean practice = has(all.toString(), "training");
        List<String> plan = new ArrayList<>(java.util.Arrays.asList(PLAN));
        if (allowStart && practice) {
            plan.add("start");
        }
        for (String w : plan) {
            for (Phrase p : phrases) {
                String t = p.text.toLowerCase(Locale.ROOT);
                if (!has(t, w) || t.length() > 40 || avoided(t)) {
                    continue;
                }
                String key = w + "@" + p.box.centerX() / 40 + "," + p.box.centerY() / 40;
                if (tapped.getOrDefault(key, 0) >= 3) {
                    continue;                    // tapped there three times already: it does nothing
                }
                return p;
            }
        }
        return null;
    }

    private static String choiceWord(String text) {
        String t = text.toLowerCase(Locale.ROOT);
        for (String w : PLAN) {
            if (has(t, w)) {
                return w;
            }
        }
        return has(t, "start") ? "start" : t;
    }

    private static boolean avoided(String t) {
        for (String a : AVOID) {
            if (has(t, a)) {
                return true;
            }
        }
        return false;
    }

    private static boolean has(String text, String w) {
        return Pattern.compile("(^|[^a-z])" + Pattern.quote(w) + "([^a-z]|$)").matcher(text.toLowerCase(Locale.ROOT)).find();
    }

    private static boolean word(String text, String... words) {
        for (String w : words) {
            if (has(text, w)) {
                return true;
            }
        }
        return false;
    }

    private static Phrase find(List<Phrase> phrases, String... words) {
        for (Phrase p : phrases) {
            if (word(p.text, words)) {
                return p;
            }
        }
        return null;
    }

    /** One move of a practice session at the usual places of a shooter's touch layout. */
    private void play(int k) throws Exception {
        int jx = (int) (0.18 * width);
        int jy = (int) (0.66 * height);
        int fx = (int) (0.80 * width);
        int fy = (int) (0.68 * height);
        int lx = (int) (0.62 * width);
        int ly = (int) (0.40 * height);
        switch (k % 8) {
            case 0:
            case 4:
                dev.swipe(jx, jy, jx, jy - (int) (0.12 * height), 500);       // walk forward
                break;
            case 1:
                dev.swipe(lx, ly, lx + (int) (0.12 * width), ly, 100);        // look right
                break;
            case 2:
            case 6:
                dev.swipe(fx, fy, fx + 1, fy, 300);                         // hold fire
                break;
            case 3:
                dev.click((int) (0.906 * width), (int) (0.52 * height));       // jump
                break;
            case 5:
                dev.swipe(lx, ly, lx - (int) (0.12 * width), ly, 100);        // look left
                break;
            default:
                dev.swipe(jx, jy, jx + (int) (0.1 * width), jy, 400);          // strafe right
                break;
        }
        log("play step " + (k % 8));
    }

    private List<Phrase> read(TextRecognizer ocr, Bitmap bmp) {
        List<Phrase> out = new ArrayList<>();
        try {
            Text text = Tasks.await(ocr.process(InputImage.fromBitmap(bmp, 0)), 30, TimeUnit.SECONDS);
            float sx = width / (float) bmp.getWidth();
            float sy = height / (float) bmp.getHeight();
            for (Text.TextBlock block : text.getTextBlocks()) {
                for (Text.Line line : block.getLines()) {
                    Rect r = line.getBoundingBox();
                    if (r == null) {
                        continue;
                    }
                    out.add(new Phrase(line.getText().trim(), new Rect((int) (r.left * sx), (int) (r.top * sy),
                            (int) (r.right * sx), (int) (r.bottom * sy))));
                }
            }
        } catch (Exception e) {
            log("read failed: " + e);
        }
        out.sort((a, b) -> b.box.width() * b.box.height() - a.box.width() * a.box.height());
        return out;
    }

    private static boolean black(Bitmap bmp) {
        int lit = 0;
        for (int i = 0; i < 200; i++) {
            int c = bmp.getPixel((int) ((i * 0.618034 % 1) * (bmp.getWidth() - 1)), (int) ((i / 200.0) * (bmp.getHeight() - 1)));
            if (((c >> 16) & 0xFF) + ((c >> 8) & 0xFF) + (c & 0xFF) > 60) {
                lit++;
            }
        }
        return lit < 4;
    }

    private void saveFrame(Bitmap bmp, int i) {
        try {
            int w = 960;
            Bitmap small = Bitmap.createScaledBitmap(bmp, w, Math.max(1, bmp.getHeight() * w / bmp.getWidth()), true);
            try (FileOutputStream f = new FileOutputStream(new File(out, String.format(Locale.ROOT, "frames/f%05d.jpg", i)))) {
                small.compress(Bitmap.CompressFormat.JPEG, 70, f);
            }
        } catch (Exception e) {
            log("frame failed: " + e);
        }
    }

    private void tap(Phrase p, String why) {
        dev.click(p.box.centerX(), p.box.centerY());
        log("tap '" + p.text + "' (" + why + ") at " + p.box.centerX() + "," + p.box.centerY());
    }

    /** A shell command as the shell user (installs, input, settings); returns its output. */
    private String sh(String cmd) {
        StringBuilder sb = new StringBuilder();
        try (ParcelFileDescriptor pfd = ua.executeShellCommand(cmd);
             InputStream in = new FileInputStream(pfd.getFileDescriptor())) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                sb.append(new String(buf, 0, n));
            }
        } catch (Exception e) {
            sb.append("error: ").append(e);
        }
        return sb.toString();
    }

    private void log(String msg) {
        String line = String.format(Locale.ROOT, "[%7.1f] %s", (System.currentTimeMillis() - t0) / 1000.0, msg);
        Log.i(TAG, line);
        try {
            log.write(line + "\n");
            log.flush();
        } catch (Exception ignored) {
            // the log is only for the results
        }
    }
}
