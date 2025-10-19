(comment) @comment
(tag) @property
(equals) @operator
(value) @normal
(delimiter) @punctuation.delimiter
(field) @none

; BeginString
(field
  (tag) @_tag
  (value) @constant 
  (#eq? @_tag "8"))  

; BodyLength
(field
  (tag) @_tag
  (value) @number
  (#eq? @_tag "9"))

; CheckSum
(field
  (tag) @_tag
  (value) @number
  (#eq? @_tag "10"))

; conceal for \x001 SOH 
((delimiter) @delimiter @punctuation.delimiter (#set! conceal "|")
  (#eq? @delimiter "")
)

