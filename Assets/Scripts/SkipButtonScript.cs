using UnityEngine;
using UnityEngine.UI;

public class SkipButtonScript : MonoBehaviour
{
    public Button button;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;

    void Start()
    {
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }

    public void OnActivate()
    {
        switch (turnLogicScript.currentGameState)
        {
            case TurnLogicScript.GameState.PlayerTurnMove:
                turnLogicScript.currentGameState = TurnLogicScript.GameState.PlayerTurnAttack;
                turnLogicScript.turnStarted = false;
                break;
            case TurnLogicScript.GameState.PlayerTurnAttack:
                turnLogicScript.currentGameState = TurnLogicScript.GameState.EnemiesTurn;
                turnLogicScript.turnStarted = false;
                break;
        }
    }
}
