# Project site

The public page for Teya Code Station, served by GitHub Pages at
<https://teya-engineering.github.io/code-station/>.

This branch holds nothing but the site. It is an orphan branch with no history in
common with `main`, so it is a deploy target rather than something to merge or
rebase. Pages serves it from the branch root.

Everything is static, with no build step. `index.html` and `assets/style.css` are
the whole page. `.nojekyll` keeps Pages from running the files through Jekyll.

## Assets

`assets/shot-*.webp` are product captures made with isolated demo data. The app
window sits on transparency and can be dropped on any background. Each image
bleeds past the bottom of its section on purpose, so the section supplies the
fold. The palette in `style.css` is sampled from `Sources/MenuBarApp/Theme.swift`
on `main` and from the captures, so the page and the app read as one system.

`assets/mark.svg` is the app icon redrawn as vector, and `assets/icon-512.png` is
the same mark from `Resources/AppIcon.icns` for the Apple touch icon.

The Design section is a small interactive prototype built directly in
`index.html` and `assets/style.css`. It mirrors the split conversation and canvas
in the app without adding a build step or JavaScript dependency.
