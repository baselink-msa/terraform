import json
import os
import urllib.request
from datetime import datetime, timedelta, timezone


def lambda_handler(event, context):
    action_group = event.get('actionGroup', 'GameScoreActionGroup')
    api_path = event.get('apiPath', '/get-game-schedule')
    http_method = event.get('httpMethod', 'GET')

    # 에이전트가 계산해서 넘겨준 startDate, endDate 받기
    parameters = event.get('parameters', [])
    start_date_str = None
    end_date_str = None

    for param in parameters:
        if param['name'] == 'startDate':
            start_date_str = param['value']
        elif param['name'] == 'endDate':
            end_date_str = param['value']

    # fallback: 파라미터 없으면 오늘 날짜로
    if not start_date_str or not end_date_str:
        kst_now = datetime.now(timezone.utc) + timedelta(hours=9)
        today_str = kst_now.date().strftime("%Y-%m-%d")
        start_date_str = start_date_str or today_str
        end_date_str = end_date_str or today_str

    # API 호출
    api_url = os.environ.get("GAME_API_URL", "https://baselink.kro.kr/api/games")

    try:
        req = urllib.request.Request(api_url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=5) as response:
            data = response.read().decode('utf-8')
            response_json = json.loads(data)

        games_list = response_json.get("data", [])

        # 날짜 필터링
        filtered_games = []
        for game in games_list:
            game_time = game.get("gameStartTime", "")
            if len(game_time) >= 10:
                game_date = game_time[:10]
                if start_date_str <= game_date <= end_date_str:
                    filtered_games.append(game)

        # 결과 포맷팅
        if filtered_games:
            result_list = []
            for g in filtered_games:
                result_list.append({
                    "일시": g.get("gameStartTime"),
                    "팀": f"{g.get('homeTeamName')} vs {g.get('awayTeamName')}",
                    "스코어": f"{g.get('homeScore', 0)}:{g.get('awayScore', 0)}",
                    "예매오픈": g.get("ticketOpenTime"),
                    "상태": g.get("status")
                })
            result_msg = json.dumps(result_list, ensure_ascii=False)
        else:
            result_msg = f"요청하신 기간({start_date_str} ~ {end_date_str})에 예정된 경기 정보가 없습니다."

    except Exception as e:
        result_msg = f"API 오류: {str(e)}"

    response_body = {"application/json": {"body": json.dumps({"result": result_msg}, ensure_ascii=False)}}

    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": action_group,
            "apiPath": api_path,
            "httpMethod": http_method,
            "httpStatusCode": 200,
            "responseBody": response_body
        }
    }


# =================================================================
# 로컬 테스트용
# =================================================================
if __name__ == "__main__":
    mock_event = {
        "actionGroup": "GameScoreActionGroup",
        "apiPath": "/get-game-schedule",
        "httpMethod": "GET",
        "parameters": [
            {"name": "startDate", "value": "2026-06-01"},
            {"name": "endDate", "value": "2026-06-30"}
        ]
    }

    print("🎬 로컬 테스트 시작...")
    response = lambda_handler(mock_event, None)
    print("\n📦 [AWS Lambda Response]")
    print(json.dumps(response, indent=2, ensure_ascii=False))
