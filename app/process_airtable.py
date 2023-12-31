# Description: This script will pull data from Airtable and save it to S3 as a parquet file
# Usage: python process_airtable.py
# Author: Angus Watters

# general utility libraries
import os
import re
from datetime import datetime
import requests

# pandas and json_normalize for flattening JSON data
import pandas as pd
from pandas import json_normalize
# import awswrangler as wr

# AWS SDK for Python (Boto3) and S3fs for S3 file system support
import boto3
import s3fs

# import the environment variables from the config.py file
from app.config import Config

# environemnt variables
# DATE = os.environ.get('DATE')
BASE_ID = os.environ.get('BASE_ID')
TABLE_ID = os.environ.get('TABLE_ID')
AIRTABLE_TOKEN = os.environ.get('AIRTABLE_TOKEN')
S3_BUCKET = os.environ.get('S3_BUCKET')

# lambda handler function
def process_airtable(event, context):

    curr_time = event['time']
    print(f"curr_time: {curr_time}")
    
    # Parse the input string
    parsed_date = datetime.strptime(curr_time, "%Y-%m-%dT%H:%M:%SZ")
    print(f"parsed_date: {parsed_date}")
    
    # Format the date as "MM/DD/YY"
    DATE = parsed_date.strftime("%m/%d/%y")
    print(f"DATE: {DATE}")

    # construct the Airtable API endpoint URL
    url = f"https://api.airtable.com/v0/{BASE_ID}/{TABLE_ID}/?filterByFormula=%7BSubmitted%20Date%7D='{DATE}'"

    # set headers with the Authorization token
    headers = {
        "Authorization": f"Bearer {AIRTABLE_TOKEN}"
    }

    # make GET request to Airtable API
    response = requests.get(url, headers=headers)

    # Check the response status
    if response.status_code == 200:
        # Successful request
        data = response.json()
        print("Records:", data.get("records"))
    else:
        # Error handling
        print(f"Error: {response.status_code} - {response.text}")

    # Extract the 'records' field from the JSON data
    records = data['records']

    # pandas JSON normalize the records data into a pandas dataframe
    df = json_normalize(records)

    # make all column names lowercase
    df.columns = df.columns.str.lower()

    # remove the 'fields' prefix from the column names, and replace any spaces or special characters with underscores
    clean_cols_names = lambda x: x.split('.', 1)[-1].replace(' ', '_').replace('[^a-zA-Z0-9_]', '')

    # Rename columns using the lambda function
    df.rename(columns=clean_cols_names, inplace=True)

    # required columns in output dataframe
    req_columns = ['id', 'createdtime', 'name', 'latitude', 'user', 'longitude',
                       'submitted_time', 'local_time', 'submitted_date', 'local_date', 'comment', 'time']
    
    # template dataframe with the required columns
    tmp_df = pd.DataFrame(columns=req_columns)

    # Merge the DataFrames, ensuring that all desired columns are present
    df = pd.merge(tmp_df, df, how='outer')

    # Reorder the columns
    df = df[req_columns]

    # Replace special characters with underscores in date variable
    clean_date = re.sub(r'[\W_]+', '_', DATE)
    # clean_date = re.sub(r'[^a-zA-Z0-9_]', '_', DATE)

    # Save the dataframe to a parquet/CSV file in S3
    s3_object = f"{S3_BUCKET}/raw/mros_airtable_{clean_date}.csv"
    # s3_object = f"{S3_BUCKET}/raw/mros_airtable_{clean_date}.parquet"

    print(f"s3_object: {s3_object}")

    print(f"Saving dataframe to {s3_object}")
    print(f"df.shape: {df.shape}")

    # # save the dataframe as a parquet to S3
    df.to_csv(s3_object)

    # wr.s3.to_parquet(df, s3_object)
    # df.to_parquet(s3_object)

    return
