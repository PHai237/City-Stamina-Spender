from __future__ import annotations

import time
from dataclasses import dataclass, field

from play import fast_click, find_nte_window, focus_window, scale_point


SANDWICH_SOURCE = (92, 655)
SANDWICH_STOCK_TRAY = (80, 522)
SANDWICH_TOPPING = (143, 422)  # bacon + lettuce + tomato

CROISSANT_SOURCE = (494, 659)
CROISSANT_STOCK_TRAY = (426, 528)
CROISSANT_TOPPING = (258, 429)  # fried egg + lettuce + tomato

CUPCAKE_SOURCE = (652, 666)
CUPCAKE_BAKED_TRAY = (852, 678)
CUPCAKE_TOPPING = (694, 429)  # apple jam

WHITE_CUP = (825, 543)
CLEAR_GLASS = (1195, 502)
PREPARED_COFFEE = (1203, 662)
WHITE_COFFEE_TOPPING = (901, 426)  # milk + topping bowl
BLACK_COFFEE_TOPPING = (1008, 414)  # whipped cream + bottle
TOMATO_CARTON = (1132, 427)

BREAD_BATCH_SIZE = 3
CUPCAKE_BATCH_SIZE = 6

BREAD_CUT_DELAY = 1.0
CUPCAKE_BAKE_DELAY = 1.3
FAST_DELAY = 0.08
CAFE_DELAY = 0.02


@dataclass
class StageOneOneActions:
    sandwich_stock: int = 0
    croissant_stock: int = 0
    cupcake_stock: int = 0
    cupcake_ready: bool = False
    _target: dict | None = field(default=None, init=False, repr=False)

    def refresh_target(self) -> bool:
        target = find_nte_window()
        if not target:
            return False
        focus_window(target["hwnd"], 0.03)
        self._target = find_nte_window() or target
        return True

    def click(self, point: tuple[int, int], delay: float = FAST_DELAY) -> bool:
        if self._target is None and not self.refresh_target():
            return False
        assert self._target is not None
        x, y = scale_point(self._target["client"], point, "left")
        fast_click(
            self._target["hwnd"],
            self._target["client"]["left"] + x,
            self._target["client"]["top"] + y,
        )
        if delay > 0:
            time.sleep(delay)
        return True

    def prewarm(self) -> bool:
        if not self.refresh_target():
            return False
        if not self.refill_sandwich():
            return False
        if not self.refill_cupcake():
            return False
        if not self.refill_croissant():
            return False
        return self.prime_cupcake()

    def refill_sandwich(self) -> bool:
        if not self.click(SANDWICH_SOURCE, BREAD_CUT_DELAY):
            return False
        self.sandwich_stock = BREAD_BATCH_SIZE
        return True

    def refill_croissant(self) -> bool:
        if not self.click(CROISSANT_SOURCE, BREAD_CUT_DELAY):
            return False
        self.croissant_stock = BREAD_BATCH_SIZE
        return True

    def refill_cupcake(self) -> bool:
        if not self.click(CUPCAKE_SOURCE, CUPCAKE_BAKE_DELAY):
            return False
        self.cupcake_stock = CUPCAKE_BATCH_SIZE
        self.cupcake_ready = False
        return True

    def prime_cupcake(self) -> bool:
        if self.cupcake_stock <= 0 and not self.refill_cupcake():
            return False
        if not self.click(CUPCAKE_BAKED_TRAY, FAST_DELAY):
            return False
        self.cupcake_stock -= 1
        self.cupcake_ready = True
        return True

    def serve_sandwich(self) -> bool:
        if self.sandwich_stock <= 0 and not self.refill_sandwich():
            return False
        if not self.click(SANDWICH_STOCK_TRAY, FAST_DELAY):
            return False
        self.sandwich_stock -= 1
        if not self.click(SANDWICH_TOPPING, FAST_DELAY):
            return False
        if self.sandwich_stock <= 0:
            self.refill_sandwich()
        return True

    def serve_croissant(self) -> bool:
        if self.croissant_stock <= 0 and not self.refill_croissant():
            return False
        if not self.click(CROISSANT_STOCK_TRAY, FAST_DELAY):
            return False
        self.croissant_stock -= 1
        if not self.click(CROISSANT_TOPPING, FAST_DELAY):
            return False
        if self.croissant_stock <= 0:
            self.refill_croissant()
        return True

    def serve_cupcake(self) -> bool:
        if not self.cupcake_ready and not self.prime_cupcake():
            return False
        self.cupcake_ready = False
        if not self.click(CUPCAKE_TOPPING, FAST_DELAY):
            return False
        self.prime_cupcake()
        return True

    def serve_black_coffee(self) -> bool:
        return (
            self.click(CLEAR_GLASS, CAFE_DELAY)
            and self.click(PREPARED_COFFEE, CAFE_DELAY)
            and self.click(BLACK_COFFEE_TOPPING, CAFE_DELAY)
        )

    def serve_white_coffee(self) -> bool:
        return (
            self.click(WHITE_CUP, CAFE_DELAY)
            and self.click(PREPARED_COFFEE, CAFE_DELAY)
            and self.click(WHITE_COFFEE_TOPPING, CAFE_DELAY)
        )

    def serve_tomato_juice(self) -> bool:
        return self.click(CLEAR_GLASS, CAFE_DELAY) and self.click(TOMATO_CARTON, CAFE_DELAY)

    def serve(self, item_id: int) -> bool:
        if item_id == 1:
            return self.serve_black_coffee()
        if item_id == 2:
            return self.serve_white_coffee()
        if item_id == 3:
            return self.serve_sandwich()
        if item_id == 4:
            return self.serve_croissant()
        if item_id == 5:
            return self.serve_cupcake()
        if item_id == 6:
            return self.serve_tomato_juice()
        return False
