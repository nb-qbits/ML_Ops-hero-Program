import pandas as pd

def clean_df(df: pd.DataFrame) -> pd.DataFrame:
    # Standardize column names
    df.columns = (
        df.columns.str.strip()
                  .str.lower()
                  .str.replace(r"[^a-z0-9]+", "_", regex=True)
                  .str.strip("_")
    )
    # Trim string columns
    for c in df.select_dtypes(include=["object"]).columns:
        df[c] = df[c].astype(str).str.strip()
    # Drop completely empty rows
    df = df.dropna(how="all")
    return df
