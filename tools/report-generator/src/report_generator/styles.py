"""Shared Matplotlib styles and theme variables for consistent Grafana-style aesthetics."""

from __future__ import annotations

import warnings
import matplotlib
import numpy as np
from scipy.interpolate import PchipInterpolator

matplotlib.use("Agg")
warnings.filterwarnings("ignore", category=UserWarning, module="matplotlib.font_manager")

# Configure Matplotlib default styles
matplotlib.rcParams['font.family'] = 'sans-serif'
matplotlib.rcParams['font.sans-serif'] = [
    'Inter', 'Roboto', 'Helvetica Neue', 'Arial', 
    'Liberation Sans', 'DejaVu Sans', 'sans-serif'
]
matplotlib.rcParams['axes.unicode_minus'] = False

# DPI configuration for reports
OUTPUT_DPI = 320

# Architecture styling configuration
ARCHITECTURE_STYLE = {
    "monolith": {
        "label": "Monolith",
        "color": "#3274D9",  # Grafana-style vibrant blue
        "linestyle": "solid",
        "marker": "o",
        "zorder": 3,
    },
    "microservices": {
        "label": "Microservices",
        "color": "#FF780A",  # Grafana-style vibrant orange
        "linestyle": (0, (5, 3)),  # Clean modern dashed line
        "marker": "s",
        "zorder": 4,
    },
}

# Service color mapping for breakdown charts
SERVICE_COLORS = {
    "api-gateway": "#5794F2",        # Light blue
    "auth-service": "#73BF69",       # Emerald green
    "item-service": "#FADE2A",       # Golden yellow
    "transaction-service": "#FF780A", # Vibrant orange
    "monolith": "#3274D9"            # Monolith blue
}

# Theme palette matching Grafana/Academic light mode
THEME = {
    "page": "#FFFFFF",
    "card": "#FFFFFF",
    "card_edge": "#E5E7EB",
    "shadow": "#FFFFFF",
    "grid": "#F3F4F6",      # Very light grid lines
    "text": "#111827",      # Near black text
    "muted": "#4B5563",
    "axis": "#E5E7EB",      # Very thin light border color
    "legend_bg": "#FFFFFF",
    "legend_text": "#111827",
}

# Scenario marker styles
SCENARIO_MARKERS = {
    "login": {"label": "Login", "marker": "o"},
    "create-transaction": {"label": "Create Transaction", "marker": "s"},
    "enriched-transactions": {"label": "Enriched Transactions", "marker": "^"},
    "sync-items": {"label": "Sync Items", "marker": "D"},
}

SCATTER_SCENARIOS = tuple(SCENARIO_MARKERS.keys())


def smooth_series(x_values: np.ndarray, y_values: np.ndarray, num_points: int = 200) -> tuple[np.ndarray, np.ndarray]:
    """Smooth a series using PchipInterpolator for nice, non-overshooting curves."""
    if len(x_values) < 3:
        return x_values, y_values

    # PchipInterpolator requires strictly increasing x-values
    sorted_indices = np.argsort(x_values)
    x_sorted = x_values[sorted_indices]
    y_sorted = y_values[sorted_indices]

    # Ensure strictly increasing (remove duplicates)
    unique_x, unique_indices = np.unique(x_sorted, return_index=True)
    unique_y = y_sorted[unique_indices]

    if len(unique_x) < 3:
        return unique_x, unique_y

    interpolator = PchipInterpolator(unique_x, unique_y)
    smooth_x = np.linspace(unique_x.min(), unique_x.max(), num_points)
    smooth_y = interpolator(smooth_x)
    return smooth_x, smooth_y
