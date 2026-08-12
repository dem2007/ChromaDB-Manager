# The application's texts

Every label, hint and error message lives in two files:

    Resources/ru.lproj/Localizable.strings
    Resources/en.lproj/Localizable.strings

Changing a text no longer requires touching the code.

## Changing a label

Open the file in any editor and find the line:

```
"Найти темы" = "Find topics";
```

**On the left is the key.** That is the string as it is written in the code; it is what the app
looks the text up by. The source language of the code is Russian, so the keys are Russian —
leave them alone: a changed key stops being found, and what stays on screen is whatever is in
the code.

**On the right is what a person sees.** Change only the right-hand side.

Build the app and the label changes:

```bash
Scripts/build-app.sh
```

## Substitutions

`%@` is a substituted text, `%lld` an integer, `%lf` a fractional number.

```
"Найдено %lld из %lld" = "Found %lld of %lld";
```

They have to be preserved: without them the value is lost and the phrase keeps a hole where it
should have been. Order matters too — it decides what goes where. `StringCatalogueTests` guards
this: it compares the set of substitutions in the key and in the text and fails if they
diverge. It also checks that every Russian key has an English line and that no English
translation is left half-Russian.

If the substitutions need to be **swapped**, number them:

```
"%@ из %@" = "%2$@ contains %1$@";
```

## When new strings appear in the code

The Russian catalogue is rebuilt with:

```bash
python3 Scripts/build-strings.py
```

It **keeps your edits** and only adds new keys. Strings that disappeared from the code are not
deleted silently: they move to the end of the file, into a "these strings are no longer in the
code" section — what to do with them is up to you.

The keys are taken from the compiler itself (`-emit-localized-strings`) rather than by parsing
the sources: `"Найдено \(count)"` becomes `"Найдено %lld"`, and guessing that from the text
means missing regularly in places where a miss goes unnoticed.

To check whether the catalogue has fallen behind the code, rewriting nothing:

```bash
python3 Scripts/build-strings.py --check
```

## Adding another language

Copy a catalogue into a new `*.lproj` folder and translate the right-hand sides:

    Resources/de.lproj/Localizable.strings

The build picks up any `*.lproj` folder on its own and no code has to change; the app chooses
the language from the system settings, and the "Interface language" setting on the "Overview"
screen can override it. Do **not** add `CFBundleLocalizations` to `Info.plist`: next to the
folders it does not extend the list of languages but doubles it.

## What the catalogue does not cover

The `chromadb-mcp` helper is launched by an agent as a separate program and has no main bundle
of its own — its messages stay as they are written in the code. There are few of them, and a
person only sees them in their agent's log.
