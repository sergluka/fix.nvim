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

; MsgType
(field
  (tag) @_tag
  (value) @type
  (#eq? @_tag "35"))

; CheckSum
(field
  (tag) @_tag
  (value) @number
  (#eq? @_tag "10"))

(field
  (tag) @_tag
  (value) @constant
  (#eq? @_tag "8"))

