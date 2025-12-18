using UnityEngine;
using UnityEngine.UI;
using System.Collections;

public class SkillBarScript : MonoBehaviour
{
    public static SkillBarScript Instance { get; private set; }
    public bool finishedBuilding = false;
    public bool finishedAssigning = false;
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject[] skillButtons;

    void Awake()
    {
        if (Instance == null)
        {
            Instance = this;
        }
        else
        {
            Destroy(this.gameObject);
        }
    }

    void OnDestroy()
    {
        if (Instance == this)
        {
            Instance = null;
        }
    }

    public void UpdateButtons()
    {
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject skillButton = this.transform.GetChild(i).gameObject;
            SkillButtonScript buttonScript = skillButton.GetComponent<SkillButtonScript>();
            buttonScript.UpdateButton();
        }
        // clear used skill and highlights
        GameObject turnLogic = GameObject.Find("Turn Logic");
        if (turnLogic != null)
        {
            TurnLogicScript turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
            if (turnLogicScript.currentGameState == TurnLogicScript.GameState.PlayerTurnAttack)
            {
                turnLogicScript.skillUsed = null;
                GameObject traversableTiles = GameObject.Find("Traversable Tiles");
                TraversableTilesScript traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
                traversableTilesScript.ClearHighlights();
            }
        }
    }

    public void DisplayCooldowns()
    {
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject skillButton = this.transform.GetChild(i).gameObject;
            SkillButtonScript buttonScript = skillButton.GetComponent<SkillButtonScript>();
            if (buttonScript.skill != null)
            {
                buttonScript.DisplayCooldown();
            }
        }
    }

    IEnumerator WaitForSkillButtons()
    {
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject skillButton = this.transform.GetChild(i).gameObject;
            SkillButtonScript skillButtonScript = skillButton.GetComponent<SkillButtonScript>();
            while (!skillButtonScript.finishedBuilding)
            {
                yield return null;
            }
        }
        finishedBuilding = true;
    }

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        int totalSkills = 8;
        skillButtons = new GameObject[totalSkills];
        for (int i = 0; i < totalSkills; i++)
        {
            GameObject skillButton = this.transform.GetChild(i).gameObject;
            skillButtons[i] = skillButton;
            SkillButtonScript skillButtonScript = skillButton.GetComponent<SkillButtonScript>();
            skillButtonScript.skillNumber = i;
        }
        finishedAssigning = true;
        StartCoroutine(WaitForSkillButtons());
    }
}
