FROM base
RUN ["/usr/local/bin/python3","-c","import pathlib; data=pathlib.Path('/proc/self/environ').read_bytes().split(b'\\0'); pathlib.Path('/oracle-env-missing-equals').write_text('present' if b'BROKEN' in data else 'absent')"]
