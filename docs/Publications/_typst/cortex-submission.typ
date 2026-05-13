// Cortex publication layout for submission-ready PDF manuscripts.
// Wire colours mirror editors/tree-sitter-wire/queries/highlights.scm capture classes.
// Profiles: workshop-abstract, preprint, camera-ready, anonymous.
// Authors are dictionaries with name, affiliation/affiliations, email, website, and orcid fields.

#let ink = rgb("#161a22")
#let muted = rgb("#5c6575")
#let rule = rgb("#cfd5df")
#let pale = rgb("#f7f8fb")
#let accent = rgb("#1e4f8a")
#let accent-soft = rgb("#edf3fa")

#let code-bg = rgb("#f8fafc")
#let code-rule = rgb("#d9e0ea")
#let code-keyword = rgb("#7a3e9d")
#let code-topology = rgb("#9a3412")
#let code-operator = rgb("#286a78")
#let code-type = rgb("#1f6f4a")
#let code-ident = rgb("#173f77")
#let code-property = rgb("#74531f")
#let code-string = rgb("#7c4a03")
#let code-comment = rgb("#697386")
#let code-number = rgb("#6b4fa3")

#let wire-keywords = (
  "contract",
  "form",
  "kind",
  "make",
  "node",
  "export",
  "let",
  "in",
  "import",
  "from",
  "use",
  "as",
  "inherit",
  "select",
  "if",
  "then",
  "else",
  "where",
)

#let wire-builtins = ("true", "false", "null")
#let wire-topology-ops = ("=>", "<>", "*")
#let wire-two-ops = ("=>", "<>", "//", "++", "|>", "<-", "->", "==", "!=", "<=", ">=", "&&", "||")
#let wire-one-ops = ("=", "@", "+", "-", "*", "/", "<", ">", "!", "|")
#let wire-delims = (":", ";", ",", ".")
#let wire-brackets = ("{", "}", "[", "]", "(", ")")

#let alpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
#let digits = "0123456789"
#let ident-chars = alpha + digits + "_"
#let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

#let tok(fill, value, strong: false, italic: false) = text(
  fill: fill,
  weight: if strong { "bold" } else { "regular" },
  style: if italic { "italic" } else { "normal" },
  value,
)

#let starts-ident(ch) = alpha.contains(ch) or ch == "_"
#let continues-ident(ch) = ident-chars.contains(ch)
#let is-digit(ch) = digits.contains(ch)

#let take-while(line, start, pred) = {
  let i = start
  while i < line.len() and pred(line.at(i)) {
    i += 1
  }
  i
}

#let take-string(line, start, delimiter) = {
  let i = start + delimiter.len()
  let escaped = false
  while i < line.len() {
    let rest = line.slice(i)
    let ch = line.at(i)
    if delimiter == "\"" and escaped {
      escaped = false
      i += 1
    } else if delimiter == "\"" and ch == "\\" {
      escaped = true
      i += 1
    } else if rest.starts-with(delimiter) {
      i += delimiter.len()
      break
    } else {
      i += 1
    }
  }
  i
}

#let wire-word(value) = {
  if value in wire-keywords {
    tok(code-keyword, value, strong: true)
  } else if value in wire-builtins {
    tok(code-number, value, strong: true)
  } else if value.len() > 0 and upper.contains(value.at(0)) {
    tok(code-type, value)
  } else {
    tok(code-ident, value)
  }
}

#let wire-highlight-line(line) = {
  let pieces = ()
  let i = 0

  while i < line.len() {
    let rest = line.slice(i)
    let ch = line.at(i)

    if rest.starts-with("#") {
      pieces.push(tok(code-comment, rest, italic: true))
      i = line.len()
    } else if rest.starts-with("/*") {
      let end = if rest.contains("*/") {
        i + rest.position("*/") + 2
      } else {
        line.len()
      }
      pieces.push(tok(code-comment, line.slice(i, end), italic: true))
      i = end
    } else if rest.starts-with("\"") {
      let end = take-string(line, i, "\"")
      pieces.push(tok(code-string, line.slice(i, end)))
      i = end
    } else if rest.starts-with("''") {
      let end = take-string(line, i, "''")
      pieces.push(tok(code-string, line.slice(i, end)))
      i = end
    } else if i + 2 <= line.len() and line.slice(i, i + 2) in wire-two-ops {
      let op = line.slice(i, i + 2)
      pieces.push(tok(if op in wire-topology-ops { code-topology } else { code-operator }, op, strong: op in wire-topology-ops))
      i += 2
    } else if ch in wire-one-ops {
      pieces.push(tok(if ch in wire-topology-ops { code-topology } else { code-operator }, ch, strong: ch in wire-topology-ops))
      i += 1
    } else if ch in wire-delims or ch in wire-brackets {
      pieces.push(tok(muted, ch))
      i += 1
    } else if is-digit(ch) {
      let end = take-while(line, i, c => is-digit(c) or c == ".")
      pieces.push(tok(code-number, line.slice(i, end)))
      i = end
    } else if starts-ident(ch) {
      let end = take-while(line, i, continues-ident)
      pieces.push(wire-word(line.slice(i, end)))
      i = end
    } else {
      pieces.push(tok(ink, ch))
      i += 1
    }
  }

  pieces.join()
}

#let mermaid-keywords = ("flowchart", "graph", "subgraph", "end", "classDef", "style", "linkStyle")
#let mermaid-highlight-line(line) = {
  let pieces = ()
  let i = 0

  while i < line.len() {
    let rest = line.slice(i)
    let ch = line.at(i)

    if rest.starts-with("%%") {
      pieces.push(tok(code-comment, rest, italic: true))
      i = line.len()
    } else if rest.starts-with("\"") {
      let end = take-string(line, i, "\"")
      pieces.push(tok(code-string, line.slice(i, end)))
      i = end
    } else if rest.starts-with("-->") or rest.starts-with("-.") or rest.starts-with(".-") {
      let end = if rest.starts-with("-->") { i + 3 } else { i + 2 }
      pieces.push(tok(code-topology, line.slice(i, end), strong: true))
      i = end
    } else if starts-ident(ch) {
      let end = take-while(line, i, continues-ident)
      let value = line.slice(i, end)
      pieces.push(if value in mermaid-keywords { tok(code-keyword, value, strong: true) } else { tok(code-ident, value) })
      i = end
    } else if ch in wire-brackets or ch in wire-delims {
      pieces.push(tok(muted, ch))
      i += 1
    } else {
      pieces.push(tok(ink, ch))
      i += 1
    }
  }

  pieces.join()
}

#let plain-highlight-line(line) = text(fill: ink, line)

#let code-lines(source, highlighter) = {
  let rows = ()
  for line in source.split("\n") {
    rows.push(box(width: 100%, highlighter(line)))
  }
  stack(dir: ttb, spacing: 1.15pt, ..rows)
}

#let code-frame-body(body, label: none) = block(
  width: 100%,
  breakable: false,
  fill: code-bg,
  stroke: 0.45pt + code-rule,
  radius: 2pt,
  inset: (x: 7pt, y: 5pt),
)[
  #set text(font: "DejaVu Sans Mono", size: 8.1pt, hyphenate: false)
  #if label != none [
    #text(font: "Libertinus Serif", size: 6.7pt, fill: muted, weight: "bold")[#label]
    #v(2pt)
  ]
  #body
]

#let code-frame(source, highlighter: plain-highlight-line, label: none) = code-frame-body(
  code-lines(source, highlighter),
  label: label,
)

#let code-lang-label(lang) = {
  if lang == none {
    none
  } else if lang == "python" {
    "Python"
  } else if lang == "typst" {
    "Typst"
  } else {
    lang
  }
}

#let metadata-row(label, value) = [
  #text(size: 8.4pt, weight: "bold", fill: muted)[#label]
  #h(0.45em)
  #text(size: 8.4pt)[#value]
]

#let profile-settings(profile) = {
  if profile == "anonymous" {
    (
      anonymous: true,
      abstract-box: false,
      show-contact: false,
      show-artifact: false,
      show-links: false,
      show-header: true,
    )
  } else if profile == "preprint" {
    (
      anonymous: false,
      abstract-box: true,
      show-contact: true,
      show-artifact: true,
      show-links: true,
      show-header: true,
    )
  } else if profile == "camera-ready" {
    (
      anonymous: false,
      abstract-box: false,
      show-contact: true,
      show-artifact: true,
      show-links: true,
      show-header: true,
    )
  } else {
    // Default profile: PDF-only workshop abstract / conference submission.
    (
      anonymous: false,
      abstract-box: false,
      show-contact: true,
      show-artifact: true,
      show-links: true,
      show-header: true,
    )
  }
}

#let content-list(value, separator: [; ]) = {
  if value == none {
    none
  } else if type(value) == array {
    value.join(separator)
  } else {
    value
  }
}

#let author-field(author, field, default: none) = {
  if type(author) == dictionary {
    author.at(field, default: default)
  } else {
    if field == "name" { author } else { default }
  }
}

#let render-author(author, show-contact: true) = {
  let name = author-field(author, "name")
  let affiliation = content-list(author-field(author, "affiliations", default: author-field(author, "affiliation")))
  let email = author-field(author, "email")
  let website = author-field(author, "website")
  let orcid = author-field(author, "orcid")
  [
    #text(size: 10.2pt, weight: "bold")[#name]
    #if orcid != none [
      #h(0.35em)
      #link("https://orcid.org/" + orcid)[#text(size: 7.4pt, fill: muted)[ORCID]]
    ]
    #if affiliation != none [
      #linebreak()
      #text(size: 8.6pt, fill: muted)[#affiliation]
    ]
    #if show-contact and (email != none or website != none) [
      #linebreak()
      #if email != none [
        #text(size: 7.9pt, fill: muted)[#link("mailto:" + email)[#email]]
      ]
      #if email != none and website != none [
        #text(size: 7.9pt, fill: muted)[ #sym.bullet ]
      ]
      #if website != none [
        #text(size: 7.9pt, fill: muted)[#link(website)[#website]]
      ]
    ]
  ]
}

#let render-authors(authors, settings) = {
  if settings.anonymous {
    [#text(size: 10.2pt, weight: "bold")[Anonymous submission]]
  } else {
    let rows = ()
    for author in authors {
      rows.push(render-author(author, show-contact: settings.show-contact))
    }
    stack(dir: ttb, spacing: 5pt, ..rows)
  }
}

#let abstract-block(abstract, boxed: false) = {
  if boxed {
    block(
      width: 100%,
      fill: pale,
      stroke: (left: 1.2pt + accent, rest: 0.45pt + rule),
      inset: (left: 8pt, right: 8pt, y: 6pt),
      radius: 1pt,
    )[
      #text(size: 9.6pt, weight: "bold", fill: accent)[Abstract.]
      #h(0.35em)
      #text(size: 9.6pt)[#abstract]
    ]
  } else {
    block(width: 100%)[
      #text(size: 9.6pt, weight: "bold")[Abstract.]
      #h(0.35em)
      #text(size: 9.6pt)[#abstract]
    ]
  }
}

#let optional-metadata(label, value) = {
  if value != none [
    #linebreak()
    #metadata-row(label, value)
  ]
}

#let frontmatter(
  title: none,
  subtitle: none,
  category: none,
  authors: (),
  settings: profile-settings("workshop-abstract"),
  abstract: none,
  keywords: (),
  ccs: (),
  repository: none,
  documentation: none,
  related-version: none,
  supplement: none,
  artifact: none,
  funding: none,
  acknowledgements: none,
  submission-id: none,
) = [
  #v(4pt)
  #align(left)[
    #set par(justify: false)
    #text(size: 18pt, weight: "bold", tracking: 0pt, hyphenate: false)[#title]
    #if subtitle != none [
      #linebreak()
      #v(2pt)
      #text(size: 10.2pt, fill: muted)[#subtitle]
    ]
    #if category != none [
      #linebreak()
      #v(2pt)
      #text(size: 8.2pt, fill: muted, weight: "bold")[#category]
    ]
    #v(8pt)
    #render-authors(authors, settings)
  ]

  #v(10pt)
  #abstract-block(abstract, boxed: settings.abstract-box)

  #v(5pt)
  #if ccs.len() > 0 [
    #metadata-row[2012 ACM Subject Classification][#ccs.join("; ")]
    #linebreak()
  ]
  #metadata-row[Keywords and phrases][#keywords.join(", ")]
  #if settings.show-links [
    #optional-metadata([Repository], repository)
    #optional-metadata([Documentation], documentation)
    #optional-metadata([Related version], related-version)
    #optional-metadata([Supplementary material], supplement)
  ]
  #if settings.show-artifact [
    #optional-metadata([Artifact], artifact)
  ]
  #optional-metadata([Funding], funding)
  #optional-metadata([Acknowledgements], acknowledgements)
  #optional-metadata([Submission ID], submission-id)
  #v(10pt)
]

#let cortex-submission(
  profile: "workshop-abstract",
  title: none,
  short-title: none,
  subtitle: none,
  category: none,
  authors: (),
  author-running: none,
  pdf-title: none,
  pdf-author: none,
  pdf-keywords: none,
  abstract: none,
  keywords: (),
  ccs: (),
  repository: none,
  documentation: none,
  related-version: none,
  supplement: none,
  artifact: none,
  funding: none,
  acknowledgements: none,
  submission-id: none,
  body,
) = [
  #let settings = profile-settings(profile)
  #let running-title = if short-title == none { title } else { short-title }
  #let running-authors = if author-running == none {
    if settings.anonymous { [Anonymous] } else { none }
  } else {
    author-running
  }
  #let document-title = if pdf-title == none { title } else { pdf-title }
  #let document-author = if settings.anonymous {
    "Anonymous"
  } else if pdf-author == none {
    ""
  } else {
    pdf-author
  }
  #let document-keywords = if pdf-keywords == none { keywords } else { pdf-keywords }

  #set document(title: document-title, author: document-author, keywords: document-keywords)
  #set page(
    paper: "a4",
    margin: (left: 25mm, right: 25mm, top: 22mm, bottom: 24mm),
    numbering: "1",
    header: if settings.show-header {
      context if counter(page).get().first() == 1 {
        none
      } else [
          #if running-authors != none [
            #text(size: 7.3pt, fill: muted)[#running-authors]
            #h(0.65em)
            #text(size: 7.3pt, fill: rule)[|]
            #h(0.65em)
          ]
          #text(size: 7.3pt, fill: muted)[#running-title]
        ]
    } else { none },
  )
  #set text(font: "Libertinus Serif", size: 9.6pt, lang: "en", fill: ink)
  #set par(justify: true, leading: 0.57em)
  #set heading(numbering: "1.1")
  #set figure(numbering: "1")
  #set math.equation(numbering: "(1)")
  #set list(indent: 1.25em, body-indent: 0.5em)
  #show heading.where(level: 1): set text(size: 12pt, weight: "bold", fill: ink)
  #show heading.where(level: 2): set text(size: 10.4pt, weight: "bold", fill: ink)
  #show raw.where(block: true): it => {
    if it.lang == "wire" {
      code-frame(it.text, highlighter: wire-highlight-line, label: "Wire")
    } else if it.lang == "mermaid" {
      code-frame(it.text, highlighter: mermaid-highlight-line, label: "Mermaid")
    } else {
      code-frame-body(it, label: code-lang-label(it.lang))
    }
  }
  #show quote.where(block: true): it => block(
    width: 100%,
    fill: accent-soft,
    stroke: (left: 1pt + accent),
    inset: (left: 8pt, right: 7pt, y: 5pt),
  )[#it.body]

  #frontmatter(
    title: title,
    subtitle: subtitle,
    category: category,
    authors: authors,
    settings: settings,
    abstract: abstract,
    keywords: keywords,
    ccs: ccs,
    repository: repository,
    documentation: documentation,
    related-version: related-version,
    supplement: supplement,
    artifact: artifact,
    funding: funding,
    acknowledgements: acknowledgements,
    submission-id: submission-id,
  )

  #body
]
