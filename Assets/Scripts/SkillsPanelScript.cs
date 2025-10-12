using UnityEngine;
using UnityEngine.UI;
using System.Collections;

public class SkillsPanelScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public bool finishedAssigning = false;
    public GameObject player;
    public EntityScript playerScript;

    public void UpdateButtons()
    {
        for (int i = 0; i < this.transform.childCount; i++)
        {
            Debug.Log("updating buttons");
            GameObject skillButton = this.transform.GetChild(i).gameObject;
            SkillButtonScript buttonScript = skillButton.GetComponent<SkillButtonScript>();
            buttonScript.UpdateButton();
        }
    }

    public void ReduceCooldowns(int number)
    {
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject skillButton = this.transform.GetChild(i).gameObject;
            SkillButtonScript skillButtonScript = skillButton.GetComponent<SkillButtonScript>();
            GameObject skill = skillButtonScript.skill;
            Skill skillScript = skill.GetComponent<Skill>();
            skillScript.ReduceCooldown(1);
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
        Debug.Log("skill buttons finished building");
        finishedBuilding = true;
    }

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<EntityScript>();
        int unlockedSkills = 8; // to-do - get this information elsewhere
        for (int i = 0; i < unlockedSkills; i++)
        {
            GameObject skillButton = this.transform.GetChild(i).gameObject;
            SkillButtonScript skillButtonScript = skillButton.GetComponent<SkillButtonScript>();
            skillButtonScript.skillNumber = i;
            Debug.Log("Assigned " + skillButtonScript.skillNumber.ToString());
        }
        finishedAssigning = true;
        StartCoroutine(WaitForSkillButtons());
    }
}
