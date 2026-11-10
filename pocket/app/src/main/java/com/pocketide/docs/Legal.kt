package com.pocketide.docs

import com.pocketide.cloudshell.CloudShell

/** Terms, privacy policy and the pointer to the open-source notices. */
internal object Legal {
    const val EFFECTIVE_DATE = "1 Oct 2026"

    /** The notices text, in the APK's assets. */
    const val NOTICES_ASSET = "notices/open-source-notices.txt"

    val terms = section(
        DocsContent.TERMS_ID,
        "Terms of use",
        "Plain terms for using PocketIDE. Effective $EFFECTIVE_DATE.",
        p("Effective $EFFECTIVE_DATE, for PocketIDE 8. The app asks you again when they change."),
        steps(
            "PocketIDE is free and open source under the Apache License 2.0. It is provided as is, without warranty of any " +
                "kind. Keep your own judgement about what you build, run and publish.",
            "There is no PocketIDE account and no server of ours. Your computer is Google Cloud Shell, under your own Google " +
                "account and Google's terms for Google Cloud, reached through Google's own gcloud on your phone under the " +
                "same terms. The agents work with your own accounts at their companies; those companies' terms, plans and " +
                "prices apply to your use of them.",
            "PocketIDE is not made, endorsed or sponsored by Anthropic, OpenAI, Google, Canonical, Coder, Microsoft or the " +
                "Eclipse Foundation. Their names and marks are used only to say whose software or service is used.",
            "Agents act on your instructions and can make mistakes. Review their work before you publish it; what you publish " +
                "is your responsibility.",
            "Acceptable use: do not use PocketIDE to break the law, attack or overload other systems, or break the terms of " +
                "Google or of an agent's company. Cloud Shell is for your own interactive work: no coin mining, network " +
                "scanning or tricks to keep it awake.",
            "You can stop at any time: sign gcloud out (Computer), delete your Cloud Shell's home folder, and Settings > " +
                "Your data on the phone, or uninstall the app.",
        ),
        p("Questions: open an issue in PocketIDE's GitHub repository."),
        link("Google Cloud terms", CloudShell.TERMS),
        link("PocketIDE on GitHub", DocLinks.ISSUES),
    )

    val privacy = section(
        DocsContent.PRIVACY_ID,
        "Privacy policy",
        "What data exists, where it is, and who can see it. Effective $EFFECTIVE_DATE.",
        p("Effective $EFFECTIVE_DATE, for PocketIDE 8."),
        p(
            "Who we are: PocketIDE is an open-source app with no server behind it. Its developer receives nothing from it: " +
                "no account, no analytics, no crash reports, no ads, no tracking.",
        ),
        p(
            "On this phone: PocketIDE's settings, including the Google account's address Cloud Shell opens with, when it " +
                "was set up and last opened, and when its connection was up in the last 8 days (Usage's count of the week's " +
                "hours); and PocketIDE's connection, in its private storage: Ubuntu with Google's gcloud, " +
                "and gcloud's sign-in (a token from Google that lets gcloud reach your Cloud Shell), which no other app can " +
                "read and which never leaves the phone except to Google. Android's cloud backup and device transfer are off " +
                "for PocketIDE.",
        ),
        p(
            "In your Google Cloud Shell: your projects, each agent's chats and sign-in, each agent's VS Code, and the " +
                "browser's profile (the cookies and sign-ins of sites opened in it, in ~/.pocketide/browser), in the home " +
                "folder only your Google account opens. Google keeps it under its privacy notice for Google Cloud, and " +
                "deletes it after ${CloudShell.DELETED_AFTER_DAYS} days without use.",
        ),
        p(
            "Chats and Usage: when you open them, PocketIDE reads each agent's chats and Cloud Shell's own numbers (memory, " +
                "disk, the tokens the agents wrote down) in your Cloud Shell, over its private connection, and shows them; " +
                "it keeps none of it on the phone and never reads a sign-in. Delete on a chat deletes it in Cloud Shell, " +
                "with its lines in that agent's prompt history.",
        ),
        p(
            "The browser: Tools > Browser shows the Chrome running in your Cloud Shell as pictures Chrome sends while you " +
                "watch, over PocketIDE's private connection; your taps and typing go back to it. None of it is kept on the " +
                "phone. The agents use the same browser and can read what it shows.",
        ),
        p(
            "What else leaves: gcloud talks to Google (its sign-in, starting Cloud Shell, the encrypted connection) under " +
                "Google's privacy notice for Google Cloud; it sends no usage reports (PocketIDE turns them off). Each agent " +
                "sends its company what it needs to work (your prompts, and the code and files it reads) under your account " +
                "there and that company's policy; PocketIDE cannot delete their copy. Downloads: Ubuntu and its updates from " +
                "Ubuntu's servers and gcloud from Google, on the phone; in Cloud Shell, the set-up script and code-server from " +
                "GitHub, the agents and the extensions you pick from Open VSX and, for the browser, Chrome for Testing from " +
                "Google; the app reads each agent's icon from Open VSX, and sends it the words you type in Extensions. They " +
                "see the request, like any website does.",
        ),
        p(
            "If an error stops the app, PocketIDE keeps what it was on this phone and shows it, with a button to copy it for " +
                "a report. It goes nowhere unless you share it.",
        ),
        p(
            "Permissions: internet and network state (the connection), a foreground service and its notice (while connected), " +
                "and biometrics (App lock). No storage, camera, microphone, location, contacts or accounts access: the Google " +
                "account comes from Android's own chooser, which gives PocketIDE only the one you pick.",
        ),
        p(
            "Deleting: in Cloud Shell, sudo rm -rf \$HOME and a restart delete your home folder; Settings > Your data signs " +
                "gcloud out and deletes PocketIDE's data on the phone, and uninstalling deletes it too (then remove \"Google " +
                "Cloud SDK\" in your Google Account's security settings). What an agent's company keeps is deleted with that company.",
        ),
        p("Children: PocketIDE is not directed at children. Google and the agents' companies each set their own minimum age."),
        p("Contact: open an issue in PocketIDE's GitHub repository. Never post a secret or personal data there."),
        link("Google Cloud privacy notice", CloudShell.PRIVACY),
        link("PocketIDE on GitHub", DocLinks.ISSUES),
    )

    val notices = section(
        DocsContent.NOTICES_ID,
        "Open-source licences",
        "The software inside PocketIDE, and each licence.",
        table(
            listOf("Part", "Licence"),
            row("PocketIDE", "Apache License 2.0"),
            row("AndroidX and Jetpack, Material icons", "Apache License 2.0"),
            row("Kotlin, kotlinx.coroutines, kotlinx.serialization", "Apache License 2.0"),
            row("OkHttp and Okio", "Apache License 2.0"),
            row("Haze", "Apache License 2.0"),
            row("PRoot (runs the connection's Linux)", "GNU General Public License, version 2"),
            row("talloc (used by PRoot)", "GNU Lesser General Public License, version 3 or later"),
            row("libandroid-shmem (used by PRoot)", "BSD 3-Clause"),
        ),
        p(
            "Downloaded by the app onto the phone, not part of it: Ubuntu (each package under its own licence) and Google's " +
                "gcloud (Apache License 2.0 and its bundled components' licences). Installed in your Cloud Shell by the set-up: " +
                "code-server (MIT) with VS Code's open-source code (MIT), the agents' extensions under their makers' licences, " +
                "and, for the browser, Google's Chrome for Testing headless shell, built from Chromium (BSD 3-Clause, with its " +
                "third-party licences in its LICENSE.headless_shell).",
        ),
        p("The full notices, with copyright lines and licence texts:"),
    )

    val all = listOf(terms, privacy, notices)
}
