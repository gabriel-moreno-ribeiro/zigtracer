# zigtracer

Um path tracer fisicamente baseado em Zig: esferas e triângulos, BVH, materiais difuso, metal, vidro e emissivo, câmera de lente fina com profundidade de campo, render multithread e escritores de PNG e PPM sem biblioteca nenhuma.

Cada imagem demora minutos e cada minuto vale a pena. É o único projeto da lista que eu abro só pra ver a saída.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/zigtracer --scene spheres --width 800 --height 450 --samples 200 --out spheres.png
./zig-out/bin/zigtracer --scene random  --samples 100 --out random.png
./zig-out/bin/zigtracer --scene cornell --width 400 --height 400 --samples 400 --out cornell.png
zig build test
```

Opções: `--width`, `--height`, `--samples` (raios por pixel), `--depth` (rebotes), `--threads` (padrão: todos os núcleos), `--seed`, `--scene spheres|random|cornell`, `--out arquivo.png|arquivo.ppm`.

## O caminho de um raio

- **Vetores** (`vec.zig`): um `Vec3` com a álgebra de sempre, reflexão, refração de Snell e amostragem de direções aleatórias por rejeição.
- **Geometria** (`scene.zig`): interseção analítica com esfera (raiz mais próxima, normal dentro/fora) e Möller–Trumbore pra triângulo. Todo objeto tem uma caixa envolvente.
- **BVH**: os objetos são divididos recursivamente na mediana dos centróides no eixo mais largo. Um raio só desce nas caixas que ele cruza (slab test), então uma cena com centenas de esferas custa meia dúzia de testes de caixa por raio em vez de centenas de esferas.
- **Materiais**: Lambert (cosseno ponderado via vetor aleatório unitário somado à normal), metal com fuzz, dielétrico com reflectância de Schlick e reflexão interna total, e superfícies emissivas. A Cornell box é iluminada só por um emissor, então a luz quica das paredes coloridas pras esferas.
- **Path tracing** (`render.zig`): cada amostra dispara um raio com jitter pelo pixel (e de um ponto aleatório da lente, pra profundidade de campo), segue até `depth` rebotes multiplicando o throughput pela atenuação e somando a emissão. Os pixels fazem a média e a saída é corrigida pra gamma.
- **Threads**: workers pegam linhas de um contador atômico, cada um com o próprio gerador semeado, então o render é determinístico pra uma seed e um número de threads.
- **Codificadores** (`image.zig`): PPM binário e PNG com IHDR/IDAT/IEND, CRC-32 e um stream zlib de blocos deflate "stored" mais Adler-32, tudo feito aqui.

Zig me ganhou pelos `comptime` e pelo `std.Thread` sem cerimônia. Me perdeu um pouco pelo `zig fmt` implacável, mas ele tem razão.

Testes: `zig build test` (álgebra, Snell, amostragem, interseções, slab test, BVH contra força bruta em raios aleatórios, direções da câmera, uma imagem renderizada com esfera emissiva vermelha, determinismo, vetores de teste de CRC/Adler, e que o PNG decodifica com o zlib da biblioteca padrão).

---

**EN:** a physically based path tracer in Zig: spheres and triangles, a median-split BVH with slab tests, Lambertian/metal/dielectric/emissive materials, a thin-lens camera, deterministic multithreaded rendering, and hand-written PNG (with CRC-32, zlib stored blocks and Adler-32) and PPM writers. `zig build test` checks the math, the BVH against brute force and the encoders. MIT.
