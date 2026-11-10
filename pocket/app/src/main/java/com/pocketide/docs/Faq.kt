package com.pocketide.docs

import com.pocketide.cloudshell.CloudShell

/** The questions owners ask, each answered in a few sentences and tied to its guide page. */
internal object Faq {
    val all: List<FaqEntry> = listOf(
        faq(
            "account",
            "start",
            "Do I need a PocketIDE account, or a credit card?",
            "No. PocketIDE has no account and no server. Cloud Shell needs only a Google account, with no card and no billing. " +
                "Each agent signs in to its own maker: a Claude, ChatGPT or Google account, or an API key.",
        ),
        faq(
            "free",
            DocsContent.COMPUTER_ID,
            "Is Cloud Shell really free? What are the limits?",
            "Yes, within Google's limits: 50 hours a week, at most 12 hours in one session, and it stops 40 minutes after you " +
                "stop using it. The 5 GB home folder is kept, until ${CloudShell.DELETED_AFTER_DAYS} days without use. Your " +
                "hours: in Cloud Shell, Session information > Usage quota.",
        ),
        faq(
            "background",
            DocsContent.COMPUTER_ID,
            "Do the agents keep working when I leave?",
            "For a while. PocketIDE disconnects 15 minutes after you leave the agents, and Google stops Cloud Shell about 40 " +
                "minutes after you stop using it; PocketIDE never keeps it awake, because that breaks Google's rules. For long " +
                "tasks, keep the agent open and look in now and then, or give it smaller steps.",
        ),
        faq(
            "phone",
            "start",
            "Does it heat the phone or drain the battery?",
            "No more than a web page: the agents and VS Code run in Google's cloud, and the phone only shows them. gcloud on " +
                "the phone only holds the connection, which uses little. The connection takes about 500 MB of storage.",
        ),
        faq(
            "in-app",
            DocsContent.IDE_ID,
            "Do the agents open inside the app, or in Chrome?",
            "Only inside PocketIDE: each agent's own VS Code, the agent alone and full screen, with PocketIDE's bar (Back, " +
                "the agents, IDE, Tools) and the keys a phone keyboard lacks; the IDE button shows the whole IDE " +
                "around it. Sign-in pages open in Chrome, never inside the " +
                "app, as Google and the AI companies require, and return to the agent by themselves.",
        ),
        faq(
            "gcloud",
            DocsContent.CONNECTION_ID,
            "Does gcloud run by itself? Is anything made in Google Cloud?",
            "gcloud installs and runs by itself: you only sign in with Google once (tap Allow on the \"Google Cloud SDK\" " +
                "page). No project, billing or OAuth client is made; only Cloud Shell's 50 free hours a week are used. " +
                "Everything runs in Cloud Shell; the phone keeps only gcloud, ssh and gcloud's sign-in, in PocketIDE's " +
                "private storage. To take the access back: Google Account > Security > Your connections to third-party apps " +
                "> Google Cloud SDK > Remove (or Computer > Sign gcloud out).",
        ),
        faq(
            "private-ports",
            DocsContent.CONNECTION_ID,
            "Can another app on my phone reach my Cloud Shell?",
            "No. Cloud Shell's ports arrive on the phone as socket files in PocketIDE's private storage, which no other app " +
                "can open, and gcloud's tunnel listens on such a file too. PocketIDE's own screens reach them through a door " +
                "on the phone's own address that answers only requests carrying its secret key. A sign-in's return port is " +
                "open only during that sign-in.",
        ),
        faq(
            "localhost-links",
            DocsContent.IDE_ID,
            "An agent shows a link to localhost. Can I open it?",
            "Yes: tap it. \"localhost\" there is Cloud Shell's own address, so PocketIDE opens it in its page viewer, through " +
                "its private door. Back goes to the page before; ✕ returns to the agent.",
        ),
        faq(
            "sign-in-localhost",
            "agents",
            "A sign-in ends at \"localhost refused to connect\".",
            "It should not: PocketIDE listens on that port during the sign-in and passes the return to the agent in Cloud " +
                "Shell. If it does (another app held the port, or Android closed PocketIDE meanwhile), open the agent in " +
                "PocketIDE and start the sign-in again.",
        ),
        faq(
            "more-extensions",
            "agents",
            "Can I add other extensions?",
            "Yes: Home > Extensions searches Open VSX from the phone, with each one's icon, publisher, downloads and rating; " +
                "tap one to read it and install it in an agent's VS Code (Cloud Shell checks the download against Open VSX's " +
                "checksum; a publisher Open VSX has not verified asks first). It also lists and removes what each VS Code has. " +
                "Tools > Install from a link takes a maker's .vsix. Each VS Code keeps its own, and they update by themselves. " +
                "Microsoft's own extensions (Pylance, C# Dev Kit, Remote, Live Share) are not on Open VSX.",
        ),
        faq(
            "to-github",
            "projects",
            "How do I put a project on GitHub?",
            "Open the Terminal (Tools > Terminal), run gh auth login once (GitHub's page opens in Chrome), then git push. " +
                "Or ask the agent to do it: it uses the same terminal.",
        ),
        faq(
            "account-safe",
            DocsContent.COMPUTER_ID,
            "Can this get my Google account in trouble?",
            "PocketIDE uses Cloud Shell as Google intends: through Google's own gcloud, unchanged in how it signs in and " +
                "talks to Google, only while you use it, and nothing keeps it awake. Each agent is told Cloud Shell's rules in " +
                "its own instructions (no mining, scanning, public tunnels or keep-awake jobs; heavy builds go to GitHub " +
                "Actions), and PocketIDE never turns off an agent's own approval settings. No one can promise zero risk: " +
                "Google decides, and what you ask an agent to do counts as yours. A separate Google account for " +
                "development keeps your main one, mail and photos apart.",
        ),
        faq(
            "which-account",
            "start",
            "Should I use my main Google account?",
            "A separate Google account just for development is recommended: the agents run code and commands in that " +
                "account's Cloud Shell, so a mistake, a leaked key or Google limiting Cloud Shell stays away from your main " +
                "Gmail, Drive and Photos. Your main account works too, the same way: Google's own sign-in, no password given to " +
                "PocketIDE. Either way, turn on 2-Step Verification.",
        ),
        faq(
            "chats-phone",
            "chats-usage",
            "Are my chats copied to the phone?",
            "No. Chats and Usage read them in Cloud Shell, over PocketIDE's private connection, each time you open them, " +
                "show them and keep nothing: once the page closes they are gone from the phone. They stay where each agent " +
                "keeps them in Cloud Shell (~/.claude, ~/.codex, Antigravity's ~/.gemini/antigravity).",
        ),
        faq(
            "usage-limits",
            "chats-usage",
            "Why does Usage show tokens, and not how much of my plan is left?",
            "The plan's limits live at each AI company and need your sign-in there, which PocketIDE never reads. Usage " +
                "adds up the tokens each agent wrote in its own files, and its buttons open each company's own usage page; " +
                "/usage in Claude Code and /status in Codex show the limits too. Codex's show on Usage when Codex wrote them " +
                "in its files.",
        ),
        faq(
            "tools-back",
            DocsContent.IDE_ID,
            "How do Tools and Back work in an agent's VS Code?",
            "Tools (the wrench) opens the agent, a file, the terminal, install from a link, all commands or the browser, " +
                "each full screen, one at a time, and turns the keys bar on for good. Back closes a menu, dialog or notice " +
                "first, then what covers the agent, and leaves " +
                "the agent only on a second Back. An extension's own page (Antigravity's settings, for example) opens full " +
                "screen too, and Back returns to the agent.",
        ),
        faq(
            "browser-watch",
            "browser",
            "Can I watch the browser the agents use, and take over?",
            "Yes: Tools > Browser shows the Chrome the agents use in Cloud Shell, live. Tap, scroll and type to take over; " +
                "Watch only keeps your taps out while an agent works. The agents drive it through Chrome's DevTools inside " +
                "Cloud Shell, as Playwright does.",
        ),
        faq(
            "browser-safe",
            "browser",
            "Is the browser safe?",
            "It runs in your Cloud Shell, never on the phone, and listens only inside it; PocketIDE shows it through its " +
                "private door. Chrome's own sandbox is on where Cloud Shell allows it (Usage says); Cloud Shell still keeps it " +
                "apart from your phone and your other data. The agents can read what it shows, signed-in pages included, so " +
                "sign in there only where you are happy for them to see. It stops by itself after 20 minutes without use.",
        ),
        faq(
            "vscode-memory",
            DocsContent.COMPUTER_ID,
            "Why does an agent's VS Code start only when I open it?",
            "Everything in Cloud Shell shares its memory. Each VS Code starts when you open its agent, so the memory goes to " +
                "the agents you use. Usage shows the memory and stops a VS Code you no longer need: what that agent was doing " +
                "ends, its chats and projects stay, and it starts again when you open it.",
        ),
        faq(
            "connection-stays",
            DocsContent.CONNECTION_ID,
            "Does the connection delete itself after the set-up? Do the agents run on my phone?",
            "It stays, because gcloud on the phone opens every connection to Cloud Shell (about 500 MB, in PocketIDE's " +
                "private storage). Only gcloud and ssh run on the phone; the agents, VS Code and your projects run in Cloud " +
                "Shell. Computer > Remove the connection deletes it, and the set-up downloads it again when you next open PocketIDE.",
        ),
        faq(
            "gcloud-update",
            DocsContent.CONNECTION_ID,
            "What if Google changes gcloud?",
            "PocketIDE checks gcloud before it connects. If an update changed how it connects, PocketIDE undoes the update, " +
                "or puts back the gcloud this version was tested with, and holds gcloud's updates until the next PocketIDE. " +
                "Only if both fail does it ask you to update PocketIDE.",
        ),
        faq(
            "set-up-again",
            DocsContent.TROUBLE_ID,
            "PocketIDE asks for the set-up again. Why?",
            "It has not opened Cloud Shell for ${CloudShell.ASK_AGAIN_AFTER_DAYS} days, and Google deletes an unused home folder " +
                "after ${CloudShell.DELETED_AFTER_DAYS}. Connect once: PocketIDE sets up again only what is missing.",
        ),
        faq(
            "more-agents",
            "agents",
            "Can I add other AI agents, like Cline or Roo Code?",
            "Yes: Home > Extensions and more agents, search for it, and tap Add as an agent (it shows for extensions Open VSX " +
                "files under AI or Chat). It gets its own VS Code on its own private port in Cloud Shell (8083 and up) and its " +
                "own projects folder (~/projects/x-<its name>), and opens from Home and the top bar alone, full screen, like " +
                "the others. Remove takes its VS Code away again; your projects stay. Each signs in its own way, often with an " +
                "API key of your own.",
        ),
        faq(
            "phone-files",
            DocsContent.IDE_ID,
            "How do I give an agent a file from my phone?",
            "Tap the agent's own add-files button (Claude Code's paper clip, Codex's +, or File > Open File): Android's picker " +
                "opens on the same tap, every time; Codex's, Cline's and Roo Code's own requests (Roo Code's, for pictures) " +
                "are answered from the phone, so VS Code's dialog does not show. The file is copied to " +
                "~/projects/<agent>/uploads in Cloud Shell, which git ignores, and the agent takes it. A folder or a save " +
                "stays in Cloud Shell's folders, where the agents work.",
        ),
        faq(
            "agent-files",
            DocsContent.IDE_ID,
            "How does an agent give me a file, like an APK, a PDF or a zip?",
            "What its chat can show (a picture, a screenshot, a short text) it shows there; anything else comes as a named " +
                "link in its chat (each agent's instructions from PocketIDE ask for this). Tap the link: PocketIDE shows " +
                "the file from Cloud Shell first, with a preview where a phone can show one (a picture, a video, sound, a " +
                "PDF's pages, text and code, a table, what an archive holds, an APK's name, version and permissions, a " +
                "folder's files), then Download. A file a link leads to directly, which a page cannot show, opens the same " +
                "sheet first: nothing is saved before you say so. Downloads go to Download/PocketIDE, with a notice; Open " +
                "and Share are on it.",
            "The link works while the file is in Cloud Shell. A file in ~/projects stays until it is deleted; one the agent " +
                "made elsewhere (in /tmp, which Cloud Shell empties when it restarts) is copied into ~/projects/<agent>/outbox " +
                "first, and kept there 30 days. Tools > Files shows the agent's whole folder the same way. VS Code's own " +
                "Download (a file's Download... in its Explorer) saves into Download/PocketIDE too.",
        ),
        faq(
            "apk-builds",
            "projects",
            "Can an agent build my Android app in Cloud Shell?",
            "Yes. Each agent's instructions say to work in Cloud Shell whenever it fits, an APK included, and to look first at " +
                "what there is (the home folder's 5 GB, the memory). It uses GitHub Actions only for what cannot run here: " +
                "an Android emulator (Cloud Shell has no KVM), macOS, iOS or Windows, more room or memory than there is, or " +
                "a job longer than your session; it decides, and tells you why. The APK comes to you as a link: Download it, " +
                "then install it from Files.",
        ),
        faq(
            "apk-install",
            DocsContent.IDE_ID,
            "Why does PocketIDE not install an APK itself?",
            "Installing apps takes a permission of its own (REQUEST_INSTALL_PACKAGES), which PocketIDE does not ask for. A " +
                "downloaded APK is in Download/PocketIDE: Open in Files (on its sheet or its notice), then tap it. The Files " +
                "app installs it and Android asks you first; the first time, Android also asks you to let Files install apps.",
        ),
        faq(
            "whole-ide",
            DocsContent.IDE_ID,
            "Can I see the whole VS Code, not only the agent?",
            "Yes: the IDE button (the arrows, at the top) shows the whole IDE around the agent, drawn smaller as on a " +
                "computer: the project's files, the editors and the agent side by side. Tap it again, or Back, for the agent " +
                "alone. Each agent has its own VS Code " +
                "on its own private port in Cloud Shell; PocketIDE opens it straight on that agent.",
        ),
        faq(
            "pages-alone",
            DocsContent.IDE_ID,
            "Why does a settings page close when I go to the agent or the whole IDE?",
            "A page (Antigravity's settings, VS Code's Settings, an extension's own page) is only ever in front, alone and " +
                "full screen, or closed: it is made for a computer's width, so it never shares the screen, even in the whole " +
                "IDE; if something opens beside it (the agent's panel, the Explorer), it has the whole screen back within a " +
                "second or two. Going to the agent or to the whole IDE closes it, and it opens full screen again next time; what you " +
                "changed in it is already saved. Files close too when the agent comes back (they save by themselves), so " +
                "whatever you open next opens alone, full screen; a terminal keeps running behind the agent.",
        ),
        faq(
            "no-repeat",
            DocsContent.COMPUTER_ID,
            "Does anything download again when Cloud Shell stops and starts?",
            "No: VS Code, the agents, their extensions, settings, sign-ins, chats and your instructions stay in Cloud Shell's " +
                "home folder, which survives every stop. The set-up runs again only after a PocketIDE update (and then fetches " +
                "only what changed) or when Google reset the home folder. Updates in Cloud Shell use Google's network, not " +
                "your phone's data; on the phone, gcloud's and Ubuntu's updates wait for Wi-Fi, once a week.",
        ),
        faq(
            "public-ip",
            DocsContent.CONNECTION_ID,
            "Cloud Shell has a public IP address. Is that safe?",
            "Yes: only Google's SSH answers on it, and only with your Google sign-in. VS Code, the agents and the browser " +
                "listen only inside Cloud Shell (127.0.0.1), and PocketIDE opens no public port or tunnel. PocketIDE also never " +
                "passes your Google Cloud sign-in into Cloud Shell, so an agent there cannot use your Cloud projects unless you " +
                "sign in there yourself.",
        ),
        faq(
            "pages-apart",
            DocsContent.CONNECTION_ID,
            "Can a web page an agent made reach my files or VS Code?",
            "No more than on a computer. PocketIDE tells Cloud Shell which page asks, so each server's own checks hold: VS " +
                "Code lets only its own page in, only files.py's own pages show your files, and only an agent's VS Code sends " +
                "files from the phone to its uploads folder. Downloads come only from Cloud Shell, through PocketIDE's door.",
        ),
        faq(
            "agent-limits",
            "agents",
            "What keeps an agent from doing something harmful?",
            "Each agent's own approvals stay on: it asks before commands and edits as its maker set it. PocketIDE adds rules " +
                "to each agent's instructions (no firewall or tunnel changes, no reading keys or sign-ins, no Google Cloud " +
                "sign-in, Cloud Shell's limits, your data sent nowhere the task does not need, no secrets in git, new GitHub " +
                "repositories private, and a question before anything public or destructive), and Claude Code's settings also " +
                "refuse those commands and files. They are seatbelts, not walls: read what an agent asks to do before you " +
                "allow it, and keep secrets out of Cloud Shell.",
        ),
        faq(
            "on-phone",
            DocsContent.YOUR_DATA_ID,
            "Should chats and files be kept on the phone too?",
            "No. The agents work in Cloud Shell and read files there, so a phone copy would not help them, and it would be a " +
                "second place to protect and lose. To give an agent a phone file, use its add-files button. To keep work, " +
                "put it on GitHub (git push).",
        ),
        faq(
            "desktop",
            DocsContent.COMPUTER_ID,
            "Does Cloud Shell have a desktop I can see?",
            "No: it is a Linux computer with no screen, used through commands. PocketIDE shows it as pages instead: each " +
                "agent's VS Code, and the agents' Chrome, live (Tools > Browser). A full desktop would need a remote-desktop " +
                "server in Cloud Shell's limited memory, so PocketIDE does not add one.",
        ),
        faq(
            "old-version",
            DocsContent.YOUR_DATA_ID,
            "I used an earlier PocketIDE. What happens to it?",
            "Version 7 opens Cloud Shell's agents inside the app; version 6's Cloud Shell set-up is updated by itself at the " +
                "first connection. PocketIDE 5 kept a computer on the phone: it stays until you delete it in Settings > Your " +
                "data, where you can first save its projects and chats as a zip. Codespaces you made with version 4 stay in " +
                "your GitHub account until you delete them there.",
        ),
    )
}
