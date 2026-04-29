#let cortex-paper(body) = [
  #set document(author: "Julius Koskela")
  #set page(
    paper: "us-letter",
    margin: (x: 0.9in, y: 0.82in),
    numbering: "1",
  )
  #set text(font: "Libertinus Serif", size: 10.5pt, lang: "en")
  #set par(justify: true, leading: 0.64em)
  #set heading(numbering: "1.1")
  #show raw.where(block: true): it => block(
    fill: luma(245),
    stroke: luma(220),
    inset: 8pt,
    radius: 3pt,
    width: 100%,
    it,
  )
  #show quote.where(block: true): it => block(
    fill: luma(248),
    stroke: (left: 2pt + luma(160)),
    inset: (left: 10pt, right: 8pt, y: 6pt),
    width: 100%,
    it,
  )
  #body
]
