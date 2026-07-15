FROM base
RUN ["/usr/local/bin/python3","-c","import os,pathlib; pathlib.Path('/oracle-env-missing-equals').write_text('empty' if os.environ['BROKEN'] == '' else 'nonempty')"]
