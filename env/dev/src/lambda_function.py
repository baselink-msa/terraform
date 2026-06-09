import json
import os
import urllib.request
from datetime import datetime, timedelta, timezone

def lambda_handler(event, context):
    action_group = event.get('actionGroup', 'GameScoreActionGroup')
    api_path = event.get('apiPath', '/get-game-schedule')
    http_method = event.get('httpMethod', 'GET')
    
    # 1. 베드락이 넘겨준 timeframe 키워드 받기
    parameters = event.get('parameters', [])
    timeframe = "오늘"  # 기본값
    for param in parameters:
        if param['name'] == 'timeframe':
            timeframe = param['value']

    # 2. 한국 시간(KST) 기준으로 현재 날짜 계산 (Lambda UTC 보정 +9시간)
    # 현재 시점: 2026년 6월 9일
    
    kst_now = datetime.now(timezone.utc) + timedelta(hours=9)
    today_date = kst_now.date()
    
    start_date = today_date
    end_date = today_date
    
    # 공백 제거로 매칭 정확도 향상
    timeframe_clean = timeframe.replace(" ", "").strip()
    
    # 🌟 3. 한국어 자연어 키워드 완벽 맵핑
    if timeframe_clean == "오늘":
        pass  # 기본값 유지
        
    elif timeframe_clean == "내일":
        start_date = today_date + timedelta(days=1)
        end_date = start_date
        
    elif timeframe_clean == "이번주":
        # 이번 주 월요일 ~ 일요일
        start_date = today_date - timedelta(days=today_date.weekday())
        end_date = start_date + timedelta(days=6)
        
    elif timeframe_clean == "지난주":
        # 지난 주 월요일 ~ 지난 주 일요일 (6월 1일~5일 경기 커버용)
        start_date = today_date - timedelta(days=today_date.weekday() + 7)
        end_date = start_date + timedelta(days=6)
        
    elif timeframe_clean in ["이번달", "6월", "6월경기"]:
        # 사용자가 "6월 경기"라고만 해도 2026-06-01 ~ 2026-06-30 범위로 고정
        start_date = today_date.replace(day=1)
        end_date = today_date.replace(day=30)
        
    elif timeframe_clean == "이번주_지난경기":
        # 이번 주 월요일 ~ 어제
        start_date = today_date - timedelta(days=today_date.weekday())
        end_date = today_date - timedelta(days=1)
        if start_date > end_date:
            start_date, end_date = today_date, today_date - timedelta(days=1)
            
    elif timeframe_clean == "다음주":
        start_date = today_date + timedelta(days=7 - today_date.weekday())
        end_date = start_date + timedelta(days=6)
        
    elif timeframe_clean == "전체":
        # 과거/미래 데이터가 모두 솎아내어질 수 있도록 범위 확대
        start_date = today_date - timedelta(days=365)
        end_date = today_date + timedelta(days=365)
        
    else: 
        # "2026-06-03" 처럼 특정 날짜로 들어올 경우 대응
        try:
            dt = datetime.strptime(timeframe_clean, "%Y-%m-%d").date()
            start_date, end_date = dt, dt
        except ValueError:
            # 파싱 실패 시, 데이터 유실 방지를 위해 이번 달 전체로 처리 (방어 코드)
            start_date = today_date.replace(day=1)
            end_date = today_date.replace(day=30)
            
    # 계산된 날짜를 문자열로 변환
    start_date_str = start_date.strftime("%Y-%m-%d")
    end_date_str = end_date.strftime("%Y-%m-%d")
    
    # 환경변수 적용 (타임아웃 5초 반영)
    api_url = os.environ.get("GAME_API_URL", "https://d1z20dvak4bl13.cloudfront.net/api/games") 
    
    try:
        req = urllib.request.Request(api_url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=5) as response:
            data = response.read().decode('utf-8')
            response_json = json.loads(data)
        
        games_list = response_json.get("data", [])
        
        # 4. 날짜 필터링
        filtered_games = []
        for game in games_list:
            game_time = game.get("gameStartTime", "")
            if len(game_time) >= 10:
                game_date = game_time[:10]
                if start_date_str <= game_date <= end_date_str:
                    filtered_games.append(game)
                    
        # 5. 결과 포맷팅
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
# 로컬 테스트용 코드 (배포할 때는 지우거나 주석 처리해도 되고, 그냥 둬도 무방합니다)
# =================================================================
if __name__ == "__main__":
    # 사용자가 "6월 경기 정보"라고 물어봤을 때 베드락이 보내줄 가짜 데이터 예시
    mock_event = {
        "actionGroup": "GameScoreActionGroup",
        "apiPath": "/get-game-schedule",
        "httpMethod": "GET",
        "parameters": [
            {
                "name": "timeframe",
                "value": "6월"  # 👈 테스트하고 싶은 키워드로 바꿔가며 확인 가능! ("오늘", "지난주" 등)
            }
        ]
    }
    
    # 람다 함수 직접 실행
    print("🎬 로컬 테스트 시작...")
    response = lambda_handler(mock_event, None)
    
    # 결과 예쁘게 출력하기
    print("\n📦 [AWS Lambda Response]")
    print(json.dumps(response, indent=2, ensure_ascii=False))