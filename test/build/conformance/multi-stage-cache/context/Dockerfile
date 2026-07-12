FROM base AS one
COPY one.txt /out/one.txt

FROM base AS two
COPY two.txt /out/two.txt

FROM base AS runtime
COPY --from=one /out/one.txt /runtime/one.txt
COPY --from=two /out/two.txt /runtime/two.txt
