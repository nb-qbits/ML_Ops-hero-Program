import pandas as pd
from app.cleaning import clean_df
import sys, os
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))


def test_clean_df_basic():
    df = pd.DataFrame({" Name ": [" Alice ", "  "], "Age": [25, None]})
    out = clean_df(df)
    assert "name" in out.columns
    assert out["name"].iloc[0] == "Alice"
