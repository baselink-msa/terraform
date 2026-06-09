import json
import os
import urllib.request
from datetime import datetime, timedelta

def lambda_handler(event, context):
    action_group = event.get('actionGroup', 'GameScoreActionGroup')
    api_path = event.get('apiPath', '/get-game-schedule')
    http_method = event.get('httpMethod', 'GET')
    
    # 1. 베드락이 넘겨준 timeframe 키워드 받기
    parameters = event.get('parameters', [])
    timeframe = "오늘"  # 아무것도 안 넘어오면 기본값
    for param in parameters:
        if param['name'] == 'timeframe':
            timeframe = param['value']

    # 2. 한국 시간(KST) 기준으로 '현재' 계산 (Lambda는 기본 UTC이므로 +9시간)
    kst_now = datetime.utcnow() + timedelta(hours=9)
    today_date = kst_now.date()
    
    start_date = today_date
    end_date = today_date
    
    # 🌟 3. timeframe 키워드별 완벽한 날짜 범위 계산기
    if timeframe == "오늘":
        pass # 기본값
    elif timeframe == "내일":
        start_date = today_date + timedelta(days=1)
        end_date = start_date
    elif timeframe == "이번주":
        # 이번 주 월요일 ~ 일요일
        start_date = today_date - timedelta(days=today_date.weekday())
        end_date = start_date + timedelta(days=6)
    elif timeframe == "이번주_지난경기":
        # 이번 주 월요일 ~ 어제
        start_date = today_date - timedelta(days=today_date.weekday())
        end_date = today_date - timedelta(days=1)
        if start_date > end_date: # 오늘이 월요일이면 지난 경기 없음
            start_date, end_date = today_date, today_date - timedelta(days=1)
    elif timeframe == "다음주":
        # 다음 주 월요일 ~ 일요일
        start_date = today_date + timedelta(days=7 - today_date.weekday())
        end_date = start_date + timedelta(days=6)
    elif timeframe == "전체":
        # 넓은 범위 (예: 과거 1년 ~ 미래 1년)
        start_date = today_date - timedelta(days=365)
        end_date = today_date + timedelta(days=365)
    else: 
        # 혹시 베드락이 "2026-06-10" 처럼 특정 날짜를 보낼 경우 대비
        try:
            dt = datetime.strptime(timeframe, "%Y-%m-%d").date()
            start_date, end_date = dt, dt
        except ValueError:
            pass # 실패 시 오늘로 간주
            
    # 계산된 날짜를 문자열로 변환
    start_date_str = start_date.strftime("%Y-%m-%d")
    end_date_str = end_date.strftime("%Y-%m-%d")
    
    api_url = os.environ["GAME_API_URL"]
    
    try:
        # DB 조회
        req = urllib.request.Request(api_url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=5) as response:
            data = response.read().decode('utf-8')
            response_json = json.loads(data)
        
        games_list = response_json.get("data", [])
        
        # 4. 계산된 날짜 안에 들어오는 경기 필터링
        filtered_games = []
        for game in games_list:
            game_time = game.get("gameStartTime", "")
            if len(game_time) >= 10:
                game_date = game_time[:10]
                # 날짜 범위 체크
                if start_date_str <= game_date <= end_date_str:
                    filtered_games.append(game)
                    
        # 5. 결과 반환
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
            result_msg = f"{timeframe}({start_date_str} ~ {end_date_str}) 기간에 예정된/진행된 경기가 없습니다."
            
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
