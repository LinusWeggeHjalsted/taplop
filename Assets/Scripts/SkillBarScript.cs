using UnityEngine;
using UnityEngine.UI;
using System.Collections;

public class SkillBarScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public bool finishedAssigning = false;
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject[] skillButtons;

    public void UpdateButtons()
    {
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject skillButton = this.transform.GetChild(i).gameObject;
            SkillButtonScript buttonScript = skillButton.GetComponent<SkillButtonScript>();
            buttonScript.UpdateButton();
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
