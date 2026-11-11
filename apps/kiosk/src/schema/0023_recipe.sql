-- 0023_recipe.sql - bill of materials for a product.
--
-- A product may be assembled from raw-material products (which are
-- themselves products with track_stock = 1). A recipe links one dish
-- to the raw materials it consumes, with quantities in the raw
-- material's own unit. Consumed on sale, reversed on void.

CREATE TABLE recipe (
    id              INTEGER PRIMARY KEY,
    product_id      INTEGER NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    ingredient_id   INTEGER NOT NULL REFERENCES product(id) ON DELETE RESTRICT,
    qty             INTEGER NOT NULL CHECK (qty > 0),
    UNIQUE (product_id, ingredient_id)
) STRICT;

CREATE INDEX recipe_product_id ON recipe(product_id);
