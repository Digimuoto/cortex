;; Indent queries for Wire.

(record         "{" @indent "}" @indent_end)
(list           "[" @indent "]" @indent_end)
(paren_or_tuple "(" @indent ")" @indent_end)
