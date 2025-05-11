tag=$(gh release view -R simdutf/simdutf --json tagName -q .tagName)
latest="${tag#v}"
ours=$(grep '\.version' build.zig.zon | sed -n 's/.*"\(.*\)".*/\1/p')

if [ "$latest" != "$ours" ]; then
    echo "simdutf is out of date; updating to $tag"
    if [ "$GITHUB_ACTIONS" = "true" ]; then
        git checkout -b update-simdutf-${tag}
    fi
    zig fetch \
        --save https://github.com/simdutf/simdutf/archive/refs/tags/$tag.tar.gz \
        --save=simdutf
    sed -i "s/^\(\s*\.version = \)\"[^\"]*\"/\1\"$latest\"/" build.zig.zon
    if [ "$GITHUB_ACTIONS" = "true" ]; then
        git commit -am "update simdutf to $tag"
        git push origin HEAD
        gh pr create \
            --title "update simdutf to $tag" \
            --head "update-simdutf-${tag}" \
            --repo "$GITHUB_REPOSITORY"
    fi
else
    echo "simdutf is up to date"
fi
