cdef class Match:
    cdef readonly Pattern re
    cdef readonly object string
    cdef readonly int pos
    cdef readonly int endpos
    cdef readonly tuple regs

    cdef _re2.StringPiece * matches
    cdef bint encoded
    cdef int nmatches
    cdef int _lastindex
    cdef tuple _groups
    cdef dict _named_groups

    def __init__(self, Pattern pattern_object, int num_groups):
        self._lastindex = -1
        self._groups = None
        self.pos = 0
        self.endpos = -1
        self.matches = _re2.new_StringPiece_array(num_groups + 1)
        self.nmatches = num_groups
        self.re = pattern_object

    property lastindex:
        def __get__(self):
            return None if self._lastindex < 1 else self._lastindex

    property lastgroup:
        def __get__(self):

            if self._lastindex < 1:
                return None
            for name, n in self.re._named_indexes.items():
                if n == self._lastindex:
                    return name.decode('utf8') if self.encoded else name
            return None

    cdef init_groups(self):
        if self._groups is not None:
            return

        cdef list groups = []
        cdef int i
        cdef _re2.const_char_ptr last_end = NULL
        cdef _re2.const_char_ptr cur_end = NULL

        for i in range(self.nmatches):
            if self.matches[i].data() == NULL:
                groups.append(None)
            else:
                if i > 0:
                    cur_end = self.matches[i].data() + self.matches[i].length()

                    if last_end == NULL:
                        last_end = cur_end
                        self._lastindex = i
                    else:
                        # The rules for last group are a bit complicated:
                        # if two groups end at the same point, the earlier one
                        # is considered last, so we don't switch our selection
                        # unless the end point has moved.
                        if cur_end > last_end:
                            last_end = cur_end
                            self._lastindex = i
                groups.append(
                        self.matches[i].data()[:self.matches[i].length()])
        self._groups = tuple(groups)

    cdef bytes _group(self, object groupnum):
        cdef int idx
        if isinstance(groupnum, int):
            idx = groupnum
            if idx > self.nmatches - 1:
                raise IndexError("no such group %d; available groups: %r"
                        % (idx, list(range(self.nmatches))))
            return self._groups[idx]
        groupdict = self._groupdict()
        if groupnum not in groupdict:
            raise IndexError("no such group %r; available groups: %r"
                    % (groupnum, list(groupdict.keys())))
        return groupdict[groupnum]

    cdef dict _groupdict(self):
        if self._named_groups is None:
            self._named_groups = {name: self._groups[n]
                    for name, n in self.re._named_indexes.items()}
        return self._named_groups

    def groups(self, default=None):
        if self.encoded:
            return tuple([default if g is None else g.decode('utf8')
                    for g in self._groups[1:]])
        return tuple([default if g is None else g
                for g in self._groups[1:]])

    def group(self, *args):
        if len(args) == 0:
            groupnum = 0
        elif len(args) == 1:
            groupnum = args[0]
        else:  # len(args) > 1:
            return tuple([self.group(i) for i in args])
        if self.encoded:
            return self._group(groupnum).decode('utf8')
        return self._group(groupnum)

    def groupdict(self):
        result = self._groupdict()
        if self.encoded:
            return {a.decode('utf8') if isinstance(a, bytes) else a:
                    b.decode('utf8') for a, b in result.items()}
        return result

    def expand(self, object template):
        """Expand a template with groups."""
        # TODO - This can be optimized to work a bit faster in C.
        if isinstance(template, unicode):
            template = template.encode('utf8')
        items = template.split(b'\\')
        for i, item in enumerate(items[1:]):
            if item[0:1].isdigit():
                # Number group
                if item[0] == b'0':
                    items[i + 1] = b'\x00' + item[1:]  # ???
                else:
                    items[i + 1] = self._group(int(item[0:1])) + item[1:]
            elif item[:2] == b'g<' and b'>' in item:
                # This is a named group
                name, rest = item[2:].split(b'>', 1)
                items[i + 1] = self._group(name) + rest
            else:
                # This isn't a template at all
                items[i + 1] = b'\\' + item
        if self.encoded:
            return b''.join(items).decode('utf8')
        return b''.join(items)

    def end(self, group=0):
        return self.span(group)[1]

    def start(self, group=0):
        return self.span(group)[0]

    def span(self, group=0):
        if isinstance(group, int):
            if group > len(self.regs):
                raise IndexError("no such group %d; available groups: %r"
                        % (group, list(range(len(self.regs)))))
            return self.regs[group]
        else:
            self._groupdict()
            if self.encoded:
                group = group.encode('utf8')
            if group not in self.re._named_indexes:
                raise IndexError("no such group %r; available groups: %r"
                        % (group, list(self.re._named_indexes)))
            return self.regs[self.re._named_indexes[group]]

    cdef _make_spans(self, char * cstring, int size, int * cpos, int * upos):
        cdef int start, end
        cdef _re2.StringPiece * piece

        spans = []
        for i in range(self.nmatches):
            if self.matches[i].data() == NULL:
                spans.append((-1, -1))
            else:
                piece = &self.matches[i]
                if piece.data() == NULL:
                    return (-1, -1)
                start = piece.data() - cstring
                end = start + piece.length()
                spans.append((start, end))

        if self.encoded:
            spans = self._convert_spans(spans, cstring, size, cpos, upos)

        self.regs = tuple(spans)

    cdef list _convert_spans(self, spans,
            char * cstring, int size, int * cpos, int * upos):
        positions = [x for x, _ in spans] + [y for _, y in spans]
        positions = sorted(set(positions))
        posdict = dict(zip(positions, self._convert_positions(
                positions, cstring, size, cpos, upos)))

        return [(posdict[x], posdict[y]) for x, y in spans]

    cdef list _convert_positions(self, positions,
            char * cstring, int size, int * cpos, int * upos):
        """Convert a list of UTF-8 byte indices to unicode indices."""
        cdef unsigned char * s = <unsigned char *>cstring
        cdef int i = 0
        cdef list result = []

        if positions[i] == -1:
            result.append(-1)
            i += 1
            if i == len(positions):
                return result
        if positions[i] == cpos[0]:
            result.append(upos[0])
            i += 1
            if i == len(positions):
                return result

        while cpos[0] < size:
            if s[cpos[0]] < 0x80:
                cpos[0] += 1
                upos[0] += 1
            elif s[cpos[0]] < 0xe0:
                cpos[0] += 2
                upos[0] += 1
            elif s[cpos[0]] < 0xf0:
                cpos[0] += 3
                upos[0] += 1
            else:
                cpos[0] += 4
                upos[0] += 1
                # wide unicode chars get 2 unichars when python is compiled
                # with --enable-unicode=ucs2
                # TODO: verify this
                emit_ifndef_py_unicode_wide()
                upos[0] += 1
                emit_endif()

            if positions[i] == cpos[0]:
                result.append(upos[0])
                i += 1
                if i == len(positions):
                    break
        return result

    def __dealloc__(self):
       _re2.delete_StringPiece_array(self.matches)

    def __repr__(self):
        return '<re2.Match object; span=%r, match=%r>' % (
                (self.pos, self.endpos), self.string)