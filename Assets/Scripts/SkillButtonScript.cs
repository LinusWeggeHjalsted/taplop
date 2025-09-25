using UnityEngine;
using UnityEngine.UI;
using System.Collections;

public class SkillButtonScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public int skillNumber;
    public Button button;
    public GameObject skillsPanel;
    public SkillsPanelScript skillsPanelScript;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject player;
    public EntityScript playerScript;
    public GameObject skill;
    public Skill skillScript;

    public GameObject cooldownPrefab;
    public GameObject cooldownOverlay;

    public void DisplayCooldown()
    {
        if (skillScript.GetCurrentCooldown() > 0)
        {
            if (cooldownOverlay == null)
            {
                cooldownOverlay =  Instantiate(cooldownPrefab, this.transform);
            }
        }
        else
        {
            if (cooldownOverlay != null)
            {
                Destroy(cooldownOverlay);
            }
        }
    }
    
    public void OnActivate()
    {
        switch (turnLogicScript.currentGameState)
        {
            case TurnLogicScript.GameState.PlayerTurnAttack:
                if (skillScript.GetCurrentCooldown() > 0)
                {
                    Debug.Log("Skill is on cooldown");
                    break;
                }
                Debug.Log("Skill " + (skillNumber + 1).ToString() + " was pressed");
                skillScript.prepareSkill(player.transform.position);
                turnLogicScript.skillUsed = skill;
                break;
        }
    }

    IEnumerator WaitForPlayerLoadout()
    {
        while (!playerScript.finishedBuilding)
        {
            yield return null;
        }
        while (!skillsPanelScript.finishedAssigning)
        {
            yield return null;
        }
        skill = playerScript.equippedSkills[skillNumber];
        skillScript = skill.GetComponent<Skill>();
        Debug.Log("finished building skill button " + skillNumber.ToString());
        finishedBuilding = true;
    }

    void Start()
    {
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<EntityScript>();
        StartCoroutine(WaitForPlayerLoadout());
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        skillsPanel = this.transform.parent.gameObject;
        skillsPanelScript = skillsPanel.GetComponent<SkillsPanelScript>();
        cooldownPrefab = Resources.Load<GameObject>("Prefabs/Cooldown Overlay Panel");
    }
}
