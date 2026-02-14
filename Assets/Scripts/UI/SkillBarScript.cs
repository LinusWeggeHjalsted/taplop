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
        DisplayCooldowns();
        // clear used skill and highlights (only in level context)
        if (GameReferences.IsInLevel())
        {
            TurnLogicScript turnLogicScript = GameReferences.GetTurnLogicScript();
            if (turnLogicScript != null && turnLogicScript.currentGameState == TurnLogicScript.GameState.PlayerTurnAttack)
            {
                turnLogicScript.skillUsed = null;
                TraversableTilesScript traversableTilesScript = GameReferences.GetTraversableTilesScript();
                if (traversableTilesScript != null)
                {
                    traversableTilesScript.ClearHighlights();
                }
            }
        }
    }

    public void DisplayCooldowns()
    {
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject skillButton = this.transform.GetChild(i).gameObject;
            SkillButtonScript buttonScript = skillButton.GetComponent<SkillButtonScript>();
            buttonScript.DisplayCooldown();
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
        // Use GameReferences helper for clean lookup
        player = GameReferences.GetPlayer();
        if (player != null)
        {
            playerScript = player.GetComponent<PlayerCharacterScript>();
        }
        StartCoroutine(WaitForSkillButtons());
    }
}
