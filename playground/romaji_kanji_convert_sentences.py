# -*- coding: utf-8 -*-
import os
import io
import sys
import openai
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
openai.api_key = os.getenv("OPENAI_API_KEY")


class GptTest:
    romaji_list = [
    'watashi no namae ha nakano desu .',
    'watashinonamaehanakanodesu .',
    '1nen ha 1gatu3ka kara hajimarimasu .',
    'kagikakko ha [ to ] de kakomimasu . ',
    'ringo ga 1ko to mikan ga 3ko arimasu . ',
    'koyuu meishi ha tokui deha arimasen . tanaka san to satou san ha yuumei nanode daijyoubu desu . ',
    'AWS Systems Manager no kanritaisyou insutansu nisuru',
    'honkijiha , EC2 insutansu wo Systems Manager no Kanritaisyou insutansu ni surumadeno tejyun desu . ',
    'AWS komyunithi- AMI de teikyou sareteiru Windows Server 2019 no AMI niha, hajimekara SSM Agent ga insuto-ru sareteimasu .',
    'watashi ha nihongo wo syaberu kotoga dekimasu .',
    'Emacs kuraianto kara riyou dekiruyouni narimashita .',
    'Emacs kara riyou dekiru kanji henkan enjin desu .',
    'toriaezu , ugokuyouni narimashita .',
    ]

    kanji_list = [
        '漢字',
        '東西南北',
        '行う',
        '東京特許許可局'
    ]

    model = "gpt-3.5-turbo"

    def set_model(self,model):
        self.model = model

    def kanji_to_yomigana(self,kanji,arg_n):
        response = openai.ChatCompletion.create(
            model=self.model,
            temperature=0.8,
            n=arg_n,
            messages=[
                {"role": "system", "content": "あなたは漢字が与えられると、ひらがなに変換するアシスタントです。"},
                {"role": "user", "content": '次をひらがなのみで表記してください。 : 東西南北'},
                {"role": "assistant", "content": 'とうざいなんぼく'},
                {"role": "user", "content": '次をひらがなのみで表記してください。 : {0}'.format(kanji)}
                ]
            )
        arr = []
        for i in range(arg_n):
            arr.append(response['choices'][i]['message']['content'])
        return(arr)
    
    def romaji_to_kanji(self,romaji,arg_n):
        response = openai.ChatCompletion.create(
            model=self.model,
            temperature=0.8,
            n=arg_n,
            messages=[
                {"role": "system", "content": "あなたはローマ字を日本語に変換するアシスタントです。"},
                {"role": "user", "content": 'ローマ字の文を漢字仮名混じり文にしてください。 : watashi no namae ha nakano desu .'},
                {"role": "assistant", "content": "私の名前は中野です。"},
                {"role": "user", "content": 'ローマ字の文を漢字仮名混じり文にしてください。 : {0}'.format(romaji)}
            ]
        )
        arr = []
        for i in range(arg_n):
            arr.append(response['choices'][i]['message']['content'])
        return(arr)

    def romaji_func(self):
        for romaji in self.romaji_list:
            result = self.romaji_to_kanji(romaji,3)
            print('IN : {0}'.format(romaji))
            for s in result:
                print('OUT: {0}'.format(s))
            print()

    def yomigana_func(self):
        for kanji in self.kanji_list:
            result = self.kanji_to_yomigana(kanji,3)
            print('IN : {0}'.format(kanji))
            for s in result:
                print('OUT: {0}'.format(s))
            print()

def main(argv):
    gptTest = GptTest()
    if(1 < len(argv)):
        gptTest.set_model(argv[1])
    gptTest.romaji_func()
    gptTest.yomigana_func()

if __name__ == "__main__":
     main(sys.argv)